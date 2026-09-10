# frozen_string_literal: true

require_relative "errors"
require_relative "util"
require_relative "task"
require_relative "cog_input_context"
require_relative "system_rune"

module Runes
  # The object an `execute do ... end` block is evaluated against, and the
  # driver for one scope (the top level, or a `call`/`map`/`repeat` iteration).
  #
  # It binds one DSL method per registered `:rune` plugin, collects the runes
  # declared by the block, runs them (concurrently for `async!` runes), and
  # computes the scope's final output.
  class ExecutionManager
    class ExecutionManagerError < Runes::Error; end
    class ExecutionManagerNotPreparedError < ExecutionManagerError; end
    class ExecutionManagerAlreadyPreparedError < ExecutionManagerError; end
    class ExecutionManagerCurrentlyRunningError < ExecutionManagerError; end
    class ExecutionScopeDoesNotExistError < ExecutionManagerError; end
    class ExecutionScopeNotSpecifiedError < ExecutionManagerError; end
    class IllegalRuneNameError < ExecutionManagerError; end
    class OutputsAlreadyDefinedError < ExecutionManagerError; end

    # Roast-compatible aliases (the spec names them both ways).
    ExecutionScopeDoesNotExist = ExecutionScopeDoesNotExistError
    ExecutionScopeNotSpecified = ExecutionScopeNotSpecifiedError
    IllegalCogNameError = IllegalRuneNameError

    attr_reader :workflow_context, :scope, :scope_value, :scope_index, :final_output,
                :cog_input_context, :execution_context

    def initialize(workflow, config_manager, all_execution_procs, workflow_context,
                   scope: nil, scope_value: nil, scope_index: 0)
      @workflow = workflow
      @config_manager = config_manager
      @all_execution_procs = all_execution_procs
      @workflow_context = workflow_context
      @scope = scope
      @scope_value = scope_value
      @scope_index = scope_index
      @cog_stack = []
      @cog_input_context = CogInputContext.new(workflow_context)
      @execution_context = ExecutionContext.new
      @outputs = nil
      @outputs_bang = nil
      @task_group = nil
      @final_output = nil
      @final_output_computed = false
    end

    def prepare!
      raise ExecutionManagerAlreadyPreparedError if preparing? || prepared?

      @preparing = true
      bind_outputs
      Runes::Workflow.register_builtin_runes! if defined?(Runes::Workflow)
      bind_registered_runes
      my_execution_procs.each { |execution_proc| @execution_context.instance_eval(&execution_proc) }
      @prepared = true
    end

    def run!
      raise ExecutionManagerNotPreparedError unless prepared?
      raise ExecutionManagerCurrentlyRunningError if running?

      @running = true
      @task_group = Runes::TaskGroup.new
      previous_group = Runes::TaskGroup.current
      Runes::TaskGroup.current = @task_group
      begin
        @cog_stack.each do |rune|
          raise Runes::WorkflowTimeoutError, "workflow timed out" if @workflow_context.expired?

          config = @config_manager.config_for(rune.class, rune.anonymous? ? nil : rune.name).deep_dup
          prepare_system_rune(rune)
          task = rune.run!(config, @cog_input_context, Runes.deep_dup(@scope_value), @scope_index, @task_group)
          next if config.async?

          begin
            task.wait
          rescue ControlFlow::Next, ControlFlow::Break
            # Loop control from a synchronous rune stops the scope; the
            # enclosing scope (or the workflow) decides what it means.
            @task_group.stop
            raise
          rescue StandardError
            @task_group.stop
            raise
          end
        end

        @task_group.wait { |task| wait_for_task_with_exception_handling(task) }
      ensure
        # W5-4: the ensure block must never mask an in-flight exception nor
        # abort its own cleanup. Capture the exception first, stop the group,
        # compute the final output only when no *real* error is in flight
        # (control flow still needs it), then always restore @running and the
        # caller's TaskGroup before re-raising any cleanup failure.
        in_flight = $!
        begin
          @task_group&.stop
        rescue StandardError
          nil
        end
        compute_error = nil
        if in_flight.nil? || in_flight.is_a?(Runes::ControlFlow::Base)
          begin
            compute_final_output
          rescue StandardError => e
            compute_error = e
          end
        end
        @running = false
        Runes::TaskGroup.current = previous_group
        raise compute_error if in_flight.nil? && compute_error
      end
    end

    def preparing?
      @preparing ||= false
    end

    def prepared?
      @prepared ||= false
    end

    def running?
      @running ||= false
    end

    # --- nested scopes (used by system runes) -------------------------

    # Builds and prepares a manager for `scope`. Raises
    # ExecutionScopeDoesNotExistError for an unknown `execute(:name)` scope.
    def build_scope_manager(scope, scope_value, scope_index)
      manager = self.class.new(
        @workflow,
        @config_manager,
        @all_execution_procs,
        @workflow_context,
        scope: scope,
        scope_value: scope_value,
        scope_index: scope_index
      )
      manager.prepare!
      manager
    end

    private

    def prepare_system_rune(rune)
      return unless rune.is_a?(Runes::SystemRune)

      rune.execution_manager = self
      return unless rune.run.nil?

      raise ExecutionScopeNotSpecifiedError,
            "no execution scope specified for #{rune.type}(:#{rune.name}); pass `run:`"
    end

    def wait_for_task_with_exception_handling(task)
      task.wait
    rescue ControlFlow::Next
      @task_group.stop
    rescue ControlFlow::Break => e
      @task_group.stop
      compute_final_output
      raise e
    rescue StandardError
      @task_group.stop
      raise
    end

    def my_execution_procs
      raise ExecutionScopeDoesNotExistError, @scope unless @all_execution_procs.key?(@scope)

      @all_execution_procs[@scope] || []
    end

    def add_rune(rune)
      @cog_input_context.register(rune)
      @cog_stack << rune
      rune
    end

    def bind_registered_runes
      Runes::Plugin.all(kind: :rune).each do |definition|
        bind_rune(definition.name, definition.klass)
        @cog_input_context.bind_rune_type(definition.name)
      end
    end

    def bind_rune(method_name, rune_class)
      on_execute_method = method(:on_execute)
      rune_method = proc do |*args, **kwargs, &input_proc|
        on_execute_method.call(rune_class, args, kwargs, input_proc)
      end
      raise IllegalRuneNameError, method_name if @execution_context.respond_to?(method_name, true)

      @execution_context.define_singleton_method(method_name, rune_method)
    end

    def on_execute(rune_class, rune_args, rune_kwargs, input_proc)
      params = rune_class.params_class.new(*rune_args, **rune_kwargs)
      add_rune(rune_class.new_from_params(params, input_proc))
    end

    def bind_outputs
      on_outputs_method = method(:on_outputs)
      on_outputs_bang_method = method(:on_outputs!)
      @execution_context.define_singleton_method(:outputs) do |&outputs_proc|
        on_outputs_method.call(outputs_proc)
      end
      @execution_context.define_singleton_method(:outputs!) do |&outputs_proc|
        on_outputs_bang_method.call(outputs_proc)
      end
    end

    def on_outputs(outputs_proc)
      raise OutputsAlreadyDefinedError if @outputs || @outputs_bang

      @outputs = outputs_proc
    end

    def on_outputs!(outputs_proc)
      raise OutputsAlreadyDefinedError if @outputs || @outputs_bang

      @outputs_bang = outputs_proc
    end

    # Memoized. `outputs!` re-raises access errors; `outputs` swallows the
    # "loop was broken" cases and yields nil.
    def compute_final_output
      return if @final_output_computed

      @final_output_computed = true
      outputs_proc = @outputs_bang || @outputs
      @final_output =
        if outputs_proc
          @cog_input_context.instance_exec(@scope_value, @scope_index, &outputs_proc)
        else
          last_rune = @cog_stack.last
          raise Runes::CogDoesNotExistError, "no runes defined in scope" unless last_rune

          @cog_input_context.cog_output(last_rune.name)
        end
    rescue ControlFlow::SkipCog, ControlFlow::Next
      nil
    rescue Runes::CogNotYetRunError, Runes::CogSkippedError, Runes::CogStoppedError => e
      raise e if @outputs_bang

      nil
    end
  end

  # The object `execute` blocks run against (separate from the manager so a
  # rune's DSL method cannot accidentally see manager internals).
  class ExecutionContext; end
end
