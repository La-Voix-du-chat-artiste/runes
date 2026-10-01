# frozen_string_literal: true

require_relative "../compat"
require_relative "../random_facade"
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
        tmpdir = File.join(ENV['TMPDIR'] || '/tmp', "runes-#{Runes::Random.hex(4)}")
        Runes::Compat.mkdir_p(tmpdir)
        begin
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
        ensure
          # A fresh tmpdir per run (W5-13): nothing leaks across runs.
          Runes::Compat.rm_rf(tmpdir)
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

      kwargs = {}
      (params.kwargs || {}).each { |key, value| kwargs[key.to_s] = value }
      { 'targets' => Array(params.targets), 'args' => Array(params.args), 'kwargs' => kwargs }
    rescue StandardError
      nil
    end

    def initialize(workflow_path, workflow_context)
      @workflow_path = File.expand_path(workflow_path.to_s)
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
    # registers the class it defines as a `:rune` plugin. CRuby only: a
    # compiled kernel has its plugins built in (Runes::Runtime).
    def use(*loadables, from: nil)
      if from
        Runes::Runtime.require_cog(from.to_s)
      else
        dir = File.dirname(File.realpath(@workflow_path))
        loadables.each do |loadable|
          begin
            Runes::Runtime.require_cog(File.join(dir, 'cogs', loadable.to_s))
          rescue LoadError => e
            raise InvalidLoadableReference, "could not load cogs/#{loadable}: #{e.message}"
          end
        end
      end

      loadables.each do |loadable|
        rune_class = Runes::Runtime.resolve_rune_class(loadable)
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

    # The workflow FILE is evaluated as source — which an AOT compiler
    # cannot do. The actual eval lives behind Runes::Runtime: CRuby
    # instance_evals it; a compiled kernel raises (a workflow shipped in a
    # compiled binary is built in at compile time, not loaded from disk).
    def extract_dsl_procs!
      Runes::Runtime.eval_workflow_source(self, @workflow_definition, File.realpath(@workflow_path))
    end

    # Constant resolution for `use` — lives behind Runes::Runtime because
    # const_get/const_defined? are exactly the dynamic-constant access a
    # compiled kernel refuses (CRuby provides the lookup; a compiled kernel
    # raises since `use` is unavailable there anyway).
    def resolve_loadable(loadable)
      Runes::Runtime.resolve_rune_class(loadable)
    end
  end
end
