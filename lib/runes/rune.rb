# frozen_string_literal: true

require "securerandom"

require_relative "plugin"
require_relative "workflow/errors"
require_relative "workflow/util"

module Runes
  # Base class for every workflow step. A Rune is a `:rune` plugin: the plugin
  # name is the DSL verb inside a workflow (`ruby`, `cmd`, `chat`, ...).
  #
  #   class Runes::Plugins::Greet < Runes::Rune
  #     plugin :greet
  #
  #     class Input < Runes::Cog::Input
  #       attr_accessor :name
  #       def validate! = raise(InvalidInputError, "'name' is required") if name.nil?
  #       def coerce(value) = (super; @name = value.to_s)
  #     end
  #
  #     class Output < Runes::Cog::Output
  #       attr_reader :text
  #       def initialize(text) = (super(); @text = text)
  #       def raw_text = text
  #     end
  #
  #     def execute(input) = Output.new("hello #{input.name}")
  #   end
  #
  # The engine drives `#run!`; subclasses implement the protected `#execute`.
  class Rune < Plugin
    class CogAlreadyStartedError < Runes::Error; end

    class << self
      # Nested `Config` if the rune defines one, else the shared base.
      def config_class
        @config_class ||= nested_or(:Config, Runes::Cog::Config)
      end

      # Nested `Input` if the rune defines one, else the shared base.
      def input_class
        @input_class ||= nested_or(:Input, Runes::Cog::Input)
      end

      # Nested `Params` if the rune defines one, else the shared base
      # (system runes use this to accept `run:`).
      def params_class
        @params_class ||= nested_or(:Params, Runes::Cog::Params)
      end

      # Anonymous runes get a UUID name so they are still addressable.
      def generate_fallback_name
        SecureRandom.uuid.to_sym
      end

      # Builds the instance described by a `Params` object. System runes
      # override this to pass their extra arguments.
      def new_from_params(params, input_proc)
        new(params.name, input_proc, anonymous: params.anonymous?)
      end

      private

      # Looks for a nested constant on the rune class or on any ancestor rune
      # class (so `Runes::SystemRune::Params` is inherited by its subclasses)
      # and falls back to the shared base.
      def nested_or(const_name, default)
        ancestor = ancestors.find do |klass|
          klass.is_a?(Class) && klass <= Runes::Rune && klass.const_defined?(const_name, false)
        end
        ancestor ? ancestor.const_get(const_name, false) : default
      end
    end

    attr_reader :name, :output

    # `name` is positional and optional in the DSL; omitting it makes the rune
    # anonymous. There is deliberately no `parallel:`/`timeout:`/`on_error:`
    # keyword — rune behaviour is configured through `config do ... end`.
    def initialize(name, input_proc, anonymous: false)
      super()
      @name = if name.nil?
        self.class.generate_fallback_name
      else
        name.is_a?(String) ? name.to_sym : name
      end
      @input_proc = input_proc
      @anonymous = anonymous || name.nil?
      @output = nil
      @skipped = false
      @failed = false
      @config = self.class.config_class.new
      @task = nil
    end

    def anonymous?
      @anonymous
    end

    # Demodulized, underscored class name ("ruby", "chat", "my_rune").
    def type
      Runes::Util.underscore(self.class.name)
    end

    # Starts the rune. Returns the Task. `task_group` is optional so the
    # documented four-argument form keeps working for embedders.
    def run!(config, input_context, scope_value, scope_index, task_group = Runes::TaskGroup.current)
      raise CogAlreadyStartedError, "rune #{type}(:#{name}) already started" if @task

      @config = config
      group = task_group || Runes::TaskGroup.new
      telemetry = input_context.respond_to?(:telemetry) ? input_context.telemetry : nil
      scope = input_context.respond_to?(:telemetry_scope) ? input_context.telemetry_scope : nil
      step_index = telemetry&.next_step_index
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      telemetry&.step_started!(rune: self, scope: scope, index: step_index)
      @task = group.async do
        input = self.class.input_class.new
        returned = if @input_proc
          input_context.instance_exec(input, scope_value, scope_index, &@input_proc)
        end
        coerce_and_validate_input!(input, returned)
        @output = execute(input)
      rescue ControlFlow::SkipCog => e
        @skipped = true
        @telemetry_error = e.message
      rescue ControlFlow::FailCog => e
        @failed = true
        @telemetry_error = "#{e.class}: #{e.message}"
        raise e if config.abort_on_failure?
      rescue ControlFlow::Next, ControlFlow::Break => e
        @skipped = true
        @telemetry_error = "#{e.class}: #{e.message}"
        raise e
      rescue StandardError => e
        @failed = true
        @telemetry_error = "#{e.class}: #{e.message}"
        raise e
      ensure
        # Emitted for every outcome (ok / skipped / failed / raised) so a
        # viewer never has a step that started and never finished.
        if telemetry
          telemetry.step_finished!(
            rune: self, scope: scope, index: step_index,
            status: (@failed ? "failed" : (@skipped ? "skipped" : "ok")),
            duration_ms: ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round(1),
            output: telemetry_output_text, error: telemetry_error_text
          )
        end
      end
      @task
    end

    # Blocks until the rune finishes. Failures are swallowed here: callers
    # that need the exception use `cog_output!`, the engine re-raises it.
    def wait
      @task&.wait
    rescue StandardError
      nil
    end

    def started?
      !@task.nil?
    end

    def skipped?
      @skipped
    end

    def failed?
      @failed || !!(@task && @task.failed?)
    end

    def stopped?
      !!(@task && @task.stopped?)
    end

    def succeeded?
      # `@output != nil` rather than `!@output.nil?` would call the output's
      # `!=`; some outputs delegate missing methods, so check identity.
      !@output.nil? && !!(@task && @task.finished?)
    end

    protected

    # Inheriting runes implement this: given a validated input, produce an
    # output. Called inside the rune's task.
    def execute(_input)
      raise NotImplementedError, "#{self.class} must implement #execute"
    end

    private

    # What a viewer shows for this step. `raw_text` is the canonical text form
    # every output exposes; a rune whose output cannot produce one contributes
    # nothing rather than raising inside an ensure block.
    def telemetry_output_text
      return nil if @output.nil?

      @output.raw_text
    rescue StandardError, NotImplementedError
      nil
    end

    def telemetry_error_text
      return nil unless @failed || @skipped

      @telemetry_error
    end

    private

    def coerce_and_validate_input!(input, return_value)
      input.validate!
    rescue Runes::Cog::Input::InvalidInputError
      input.coerce(return_value)
      input.validate!
    end
  end

  # Roast spelling: `Runes::Cog` is `Runes::Rune`, so `Runes::Cog::Input`,
  # `Runes::Cog::Output`, `Runes::Cog::Config` and `Runes::Cog::Params` all
  # resolve. `Cog::Input::InvalidInputError` is the Roast-compatible error.
  Cog = Rune unless defined?(Runes::Cog)
end

require_relative "workflow/cog"
