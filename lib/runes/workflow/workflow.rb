# frozen_string_literal: true

require "tmpdir"
require "pathname"

require_relative "errors"
require_relative "util"
require_relative "workflow_params"
require_relative "config_manager"
require_relative "execution_manager"

module Runes
  # A workflow is a plain `.rb` file evaluated with `instance_eval` against an
  # instance of this class. The file calls `config`, `execute` and `use`; the
  # blocks are collected first and evaluated in the second phase, after every
  # `use` has registered its runes.
  class Workflow
    class WorkflowError < Runes::Error; end
    class WorkflowNotPreparedError < WorkflowError; end
    class WorkflowAlreadyPreparedError < WorkflowError; end
    class WorkflowAlreadyStartedError < WorkflowError; end
    class InvalidLoadableReference < WorkflowError; end

    class << self
      # Build, prepare and run a workflow file. Returns the Workflow instance
      # (its final output is `#final_output`).
      #
      # `timeout:` (seconds, or `RUNES_WORKFLOW_TIMEOUT_S`) is a wall-clock
      # deadline for the whole run: the execution manager and `repeat` check
      # it and raise `Runes::WorkflowTimeoutError` (W5-10).
      def from_file(workflow_path, params = Runes::WorkflowParams.new, timeout: nil)
        timeout = workflow_timeout if timeout.nil?
        Dir.mktmpdir("runes-") do |tmpdir|
          workflow = new(
            workflow_path,
            Runes::WorkflowContext.new(
              params: Runes::WorkflowParams.from(params),
              tmpdir: tmpdir,
              workflow_dir: File.dirname(File.expand_path(workflow_path.to_s)),
              timeout: timeout
            )
          )
          workflow.prepare!
          workflow.start!
          workflow
        end
      end

      # Convenience wrapper returning the final output directly.
      def run_file(workflow_path, params = Runes::WorkflowParams.new, timeout: nil)
        from_file(workflow_path, params, timeout: timeout).final_output
      end

      def workflow_timeout
        raw = ENV["RUNES_WORKFLOW_TIMEOUT_S"]
        return nil if raw.nil? || raw.to_s.strip.empty?

        value = Float(raw)
        value.positive? ? value : nil
      rescue ArgumentError, TypeError
        nil
      end
    end

    attr_reader :workflow_path, :workflow_context, :final_output, :config_manager
    # The run's telemetry context: one id and one sink, shared by every step
    # and every nested scope so a viewer can stitch the run back together.
    attr_reader :telemetry_context

    def telemetry_params
      params = @workflow_context.respond_to?(:params) ? @workflow_context.params : nil
      return nil if params.nil?

      { 'targets' => Array(params.targets), 'args' => Array(params.args),
        'kwargs' => (params.kwargs || {}).transform_keys(&:to_s) }
    rescue StandardError
      nil
    end

    def initialize(workflow_path, workflow_context)
      @workflow_path = Pathname.new(workflow_path)
      @workflow_context = workflow_context
      @workflow_definition = File.read(workflow_path)
      @config_procs = []
      @execution_procs = { nil => [] }
      @config_manager = nil
      @execution_manager = nil
      @final_output = nil
    end

    # --- the DSL ------------------------------------------------------

    def config(&block)
      @config_procs << block
    end

    # `execute` with no scope is the entry point (several accumulate and run
    # in order); `execute(:name)` defines a named scope invoked by
    # `call`/`map`/`repeat`.
    def execute(scope = nil, &block)
      key = scope.nil? ? nil : scope.to_sym
      (@execution_procs[key] ||= []) << block
    end

    # Loads a local `cogs/<name>.rb` (or a gem when `from:` is given) and
    # registers the class it defines as a `:rune` plugin.
    def use(*loadables, from: nil)
      if from
        require from.to_s
      else
        dir = File.dirname(@workflow_path.realpath.to_s)
        loadables.each do |loadable|
          begin
            require File.join(dir, "cogs", loadable.to_s)
          rescue LoadError => e
            raise InvalidLoadableReference, "could not load cogs/#{loadable}: #{e.message}"
          end
        end
      end

      loadables.each do |loadable|
        rune_class = resolve_loadable(loadable)
        raise InvalidLoadableReference, "#{loadable} class not found" unless rune_class

        unless rune_class.is_a?(Class) && rune_class < Runes::Rune
          raise InvalidLoadableReference,
                "#{rune_class} is not a subclass of a usable Runes primitive (Runes::Rune)"
        end

        unless Runes::Plugin.registered?(rune_class.plugin_name, kind: :rune)
          rune_class.plugin(rune_class.plugin_name, kind: :rune)
        end
      end
      loadables
    end

    # --- lifecycle ----------------------------------------------------

    def prepare!
      raise WorkflowAlreadyPreparedError if preparing? || prepared?

      @preparing = true
      self.class.register_builtin_runes!
      extract_dsl_procs!
      @config_manager = ConfigManager.new(@config_procs, @workflow_context)
      @config_manager.prepare!
      @telemetry_context = Runes::Telemetry::Context.new(workflow: @workflow_path, params: telemetry_params)
      @execution_manager = ExecutionManager.new(
        self,
        @config_manager,
        @execution_procs,
        @workflow_context,
        scope_value: @workflow_context.params,
        telemetry: @telemetry_context
      )
      @execution_manager.prepare!
      @prepared = true
    end

    def start!
      raise WorkflowNotPreparedError unless @execution_manager

      raise WorkflowAlreadyStartedError if started? || completed?

      @started = true
      begin
        @execution_manager.run!
      rescue ControlFlow::Next, ControlFlow::Break
        # `next!`/`break!` at the top level just end the scope: loops only
        # exist inside call/map/repeat.
      end
      @final_output = @execution_manager.final_output
      @completed = true
    end

    def preparing?
      @preparing ||= false
    end

    def prepared?
      @prepared ||= false
    end

    def started?
      @started ||= false
    end

    def completed?
      @completed ||= false
    end

    def params
      @workflow_context.params
    end

    private

    def extract_dsl_procs!
      instance_eval(@workflow_definition, @workflow_path.realpath.to_s, 1)
    end

    # Checks `Runes::Plugins::<Camelized>` first (the tidy place for a plugin),
    # then the top-level `<Camelized>` constant (the Roast `cogs/foo.rb`
    # convention).
    def resolve_loadable(loadable)
      camelized = Runes::Util.camelize(loadable)
      ["Runes::Plugins::#{camelized}", camelized].each do |constant|
        return Object.const_get(constant) if Object.const_defined?(constant)
      end
      nil
    end
  end
end
