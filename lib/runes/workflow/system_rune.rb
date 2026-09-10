# frozen_string_literal: true

require_relative "../rune"

module Runes
  # Base class for the engine's *system* runes: `call`, `map` and `repeat`.
  # They differ from ordinary runes in two ways:
  #
  #   * their DSL method takes a required-by-the-engine `run:` scope name
  #     (`map(:rows, run: :process_row) { ... }`), and
  #   * they need to drive nested `Runes::ExecutionManager`s, so the engine
  #     hands them the parent manager through `#execution_manager` before
  #     `#run!` is called.
  #
  # A system rune implementation overrides `#execute(input)` and calls
  # `execution_manager.build_scope_manager(scope, value, index)` followed by
  # `#run!` on the returned manager, then builds its `Output` from the manager
  # (see `Runes::Plugins::Call`, `Map`, `Repeat` for the shipped ones).
  class SystemRune < Rune
    class Params < Runes::Cog::Params
      attr_reader :run

      def initialize(name = nil, run: nil)
        super(name)
        @run = run
      end
    end

    def self.new_from_params(params, input_proc)
      new(params.name, input_proc, anonymous: params.anonymous?, run: params.run)
    end

    # The `execute(:name)` scope this rune invokes. nil means the workflow
    # forgot `run:`; the engine raises ExecutionScopeNotSpecifiedError.
    attr_reader :run

    # Assigned by ExecutionManager#run! immediately before #run!.
    attr_accessor :execution_manager

    def initialize(name, input_proc, anonymous: false, run: nil)
      super(name, input_proc, anonymous: anonymous)
      @run = run
      @execution_manager = nil
    end

    protected

    def execute(_input)
      raise NotImplementedError, "#{self.class} must implement #execute"
    end

    # Builds (and prepares) a nested execution manager for `run`, using this
    # rune's parent manager. Raises ExecutionScopeDoesNotExistError for an
    # unknown scope, via the parent's scope table.
    def build_scope(value, index)
      raise Runes::ExecutionManager::ExecutionScopeNotSpecifiedError, "no execution scope specified" if run.nil?

      execution_manager.build_scope_manager(run, value, index)
    end

    # Build, prepare and run a nested scope, returning the manager.
    def run_scope(value, index)
      manager = build_scope(value, index)
      manager.run!
      manager
    end
  end
end
