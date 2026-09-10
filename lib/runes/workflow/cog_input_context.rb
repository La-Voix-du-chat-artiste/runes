# frozen_string_literal: true

require_relative "util"
require_relative "errors"
require_relative "workflow_params"

module Runes
  # The object that is `self` inside a rune's input block. It exposes the
  # control-flow verbs (`skip!`/`fail!`/`next!`/`break!`), the workflow params
  # (`target!`, `template`, ...) and one output accessor trio per rune that has
  # been declared in the current scope:
  #
  #   X(name)   -> output, or nil for not-yet-run/skipped/failed/stopped;
  #               raises CogDoesNotExistError for an unknown name
  #   X!(name)  -> waits, then returns a deep copy of the output or raises
  #   X?(name)  -> boolean
  class CogInputContext
    include Runes::WorkflowParamAccessors

    class ContextNotFoundError < Runes::Error; end
    # A rune whose name collides with a context method (e.g. `template`) would
    # silently break that method; refuse it at bind time, like
    # ExecutionManager/ConfigManager do (W5-13).
    class IllegalRuneNameError < Runes::Error; end

    # Roast spells these under `Roast::CogInputManager`; keep both reachable.
    CogOutputAccessError = Runes::CogOutputAccessError
    CogDoesNotExistError = Runes::CogDoesNotExistError
    CogNotYetRunError = Runes::CogNotYetRunError
    CogSkippedError = Runes::CogSkippedError
    CogFailedError = Runes::CogFailedError
    CogStoppedError = Runes::CogStoppedError

    def initialize(workflow_context)
      @workflow_context = workflow_context
      @runes = {}
    end

    # --- control flow -------------------------------------------------

    def skip!(message = nil)
      raise ControlFlow::SkipCog, message
    end

    def fail!(message = nil)
      raise ControlFlow::FailCog, message
    end

    def next!(message = nil)
      raise ControlFlow::Next, message
    end

    def break!(message = nil)
      raise ControlFlow::Break, message
    end

    # --- rune bookkeeping ---------------------------------------------

    def register(rune)
      raise Runes::RuneAlreadyDefinedError, rune.name if @runes.key?(rune.name)

      @runes[rune.name] = rune
      rune
    end

    # Binds the output accessor trio for one registered rune *type*, e.g.
    # `ruby(name)`, `ruby?(name)`, `ruby!(name)`. Called once per plugin at
    # prepare time, before any scope runs.
    def bind_rune_type(method_name)
      context = self
      question = "#{method_name}?"
      bang = "#{method_name}!"
      [method_name, question, bang].each do |name|
        if context.respond_to?(name, true)
          raise IllegalRuneNameError,
                "rune name #{method_name.inspect} collides with an existing #{name.inspect} context method"
        end
      end
      define_singleton_method(method_name) { |name| context.cog_output(name) }
      define_singleton_method(question) { |name| context.cog_output?(name) }
      define_singleton_method(bang) { |name| context.cog_output!(name) }
    end

    def key?(name)
      @runes.key?(normalize(name))
    end

    def runes
      @runes.dup
    end

    # --- output access (also reachable through the bound X/X!/X? methods) ---

    def cog_output(name)
      cog_output!(name)
    rescue Runes::CogOutputAccessError => e
      # Only a genuinely unknown name is an error here; everything else is a
      # nil-able state (not yet run / skipped / failed / stopped).
      raise e if e.is_a?(Runes::CogDoesNotExistError)

      nil
    end

    def cog_output?(name)
      !cog_output(name).nil?
    end

    def cog_output!(name)
      name = normalize(name)
      raise Runes::CogDoesNotExistError, name unless @runes.key?(name)

      rune = @runes[name]
      rune.wait # accessing a running async rune blocks until it finishes
      raise Runes::CogSkippedError, name if rune.skipped?
      raise Runes::CogFailedError, name if rune.failed?
      raise Runes::CogStoppedError, name if rune.stopped?
      raise Runes::CogNotYetRunError, name unless rune.succeeded?

      rune.output.deep_dup
    end

    # --- system-rune helpers ------------------------------------------
    # These operate on the opaque outputs of `call`/`map`/`repeat`.

    # Extract the final output of a `call` rune; with a block, run the block
    # in the called scope's input context as `|final, scope_value, scope_index|`.
    def from(call_output, &block)
      manager = execution_manager_of(call_output)
      raise ContextNotFoundError, "not a call output" if manager.nil?

      return manager.final_output unless block

      manager.cog_input_context.instance_exec(
        manager.final_output,
        Runes.deep_dup(manager.scope_value),
        manager.scope_index,
        &block
      )
    end

    # Collect a `map` rune's iteration outputs into an Array. With a block,
    # each block runs in that iteration's context as `|final, item, index|`.
    def collect(map_output, &block)
      managers = execution_managers_of(map_output)
      raise ContextNotFoundError, "not a map output" if managers.nil?

      if block
        managers.map do |manager|
          next if manager.nil?

          manager.cog_input_context.instance_exec(
            manager.final_output,
            manager.scope_value,
            manager.scope_index,
            &block
          )
        end
      else
        managers.map { |manager| manager&.final_output }
      end
    end

    # Reduce a `map`/`repeat` results output. A nil block return leaves the
    # accumulator untouched (Roast's documented behaviour).
    def reduce(map_output, initial_value = nil, &block)
      managers = execution_managers_of(map_output)
      raise ContextNotFoundError, "not a map output" if managers.nil?

      accumulator = initial_value
      managers.compact.each do |manager|
        new_accumulator = manager.cog_input_context.instance_exec(
          accumulator,
          manager.final_output,
          manager.scope_value,
          manager.scope_index,
          &block
        )
        accumulator = new_accumulator unless new_accumulator.nil?
      end
      accumulator
    end

    private

    def normalize(name)
      name.is_a?(String) ? name.to_sym : name
    end

    def execution_manager_of(output)
      output.respond_to?(:execution_manager) ? output.execution_manager : nil
    end

    def execution_managers_of(output)
      output.respond_to?(:execution_managers) ? output.execution_managers : nil
    end
  end
end
