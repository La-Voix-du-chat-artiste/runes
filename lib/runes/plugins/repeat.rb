# frozen_string_literal: true

require_relative "../rune"
require_relative "../workflow/system_rune"
require_relative "call"
require_relative "map"

module Runes
  module Plugins
    # The `repeat` system rune: run a named `execute(:scope)` repeatedly until
    # the scope calls `break!` or `max_iterations` is reached. Each iteration's
    # final output becomes the next iteration's scope value.
    class Repeat < Runes::SystemRune
      plugin :repeat, description: "Run a scope repeatedly until it breaks"

      # Last-resort guard so a `repeat` that never calls `break!` cannot hang
      # a run forever (W5-10). Override with `repeat { max_iterations(n) }`,
      # or opt out with `no_iteration_limit!` / RUNES_REPEAT_MAX_ITERATIONS=0.
      DEFAULT_MAX_ITERATIONS = 10_000
      ENV_MAX_ITERATIONS = "RUNES_REPEAT_MAX_ITERATIONS"

      class IterationLimitExceededError < Runes::Error; end
      class TimeoutError < Runes::Error; end

      class Config < Runes::Cog::Config
        # A hard cap: reaching it raises instead of stopping quietly, so a
        # runaway loop is reported rather than silently truncated.
        def max_iterations(limit)
          @values[:max_iterations] = limit
        end

        def use_default_max_iterations!
          @values.delete(:max_iterations)
        end

        def no_iteration_limit!
          @values[:unlimited_iterations] = true
        end

        def unlimited_iterations?
          !!@values[:unlimited_iterations]
        end

        def valid_max_iterations
          raw = @values[:max_iterations]
          return nil if raw.nil?

          value = Integer(raw)
          raise InvalidConfigError, "'max_iterations' must be >= 1, got #{raw.inspect}" if value < 1

          value
        rescue ArgumentError, TypeError
          raise InvalidConfigError, "'max_iterations' must be an Integer, got #{raw.inspect}"
        end

        # Wall clock for this repeat rune; nil = no per-rune timeout.
        def timeout(seconds)
          @values[:timeout] = seconds
        end

        def use_default_timeout!
          @values.delete(:timeout)
        end

        def valid_timeout
          raw = @values[:timeout]
          return nil if raw.nil?

          value = Float(raw)
          raise InvalidConfigError, "'timeout' must be positive, got #{raw.inspect}" unless value.positive?

          value
        rescue ArgumentError, TypeError
          raise InvalidConfigError, "'timeout' must be a number of seconds, got #{raw.inspect}"
        end

        def validate!
          valid_max_iterations
          valid_timeout
        end
      end

      class Input < Runes::Cog::Input
        attr_accessor :value, :index, :max_iterations

        def initialize
          super
          @index = 0
        end

        def validate!
          raise InvalidInputError, "'value' is required" if value.nil? && !coerce_ran?
          if max_iterations && max_iterations < 1
            raise InvalidInputError, "'max_iterations' must be >= 1 if present"
          end
        end

        def coerce(input_return_value)
          super
          @value = input_return_value unless Runes.present?(@value)
        end
      end

      class Output < Runes::Cog::Output
        attr_reader :execution_managers

        def initialize(execution_managers)
          super()
          @execution_managers = execution_managers
        end

        # The final output of the last iteration that ran.
        def value
          @execution_managers.last&.final_output
        end

        def iteration(index)
          Runes::Plugins::Call::Output.new(@execution_managers.fetch(index))
        end

        def first
          iteration(0)
        end

        def last
          iteration(-1)
        end

        # A map-style handle so `collect`/`reduce` work on repeat results too.
        def results
          Runes::Plugins::Map::Output.new(@execution_managers)
        end

        def raw_text
          value.to_s
        end
      end

      protected

      def execute(input)
        managers = []
        scope_value = Runes.deep_dup(input.value)
        hard_cap = @config.valid_max_iterations
        soft_cap = input.max_iterations
        # An explicit `max_iterations` on the rune is already a bound, so the
        # safety-net default only applies when nothing bounds the loop.
        hard_cap ||= default_max_iterations if soft_cap.nil?
        timeout = @config.valid_timeout
        deadline = monotonic + timeout if timeout

        loop do
          raise WorkflowTimeoutError, "workflow timed out during repeat(:#{name})" if workflow_context.expired?
          raise TimeoutError, "repeat(:#{name}) timed out after #{timeout}s" if deadline && monotonic >= deadline
          if hard_cap && managers.length >= hard_cap
            raise IterationLimitExceededError,
                  "repeat(:#{name}) exceeded #{hard_cap} iterations without breaking; " \
                  "call break! or set max_iterations (RUNES_REPEAT_MAX_ITERATIONS=0 disables the guard)"
          end

          manager = execution_manager.build_scope_manager(run, scope_value, input.index + managers.length)
          managers << manager
          begin
            manager.run!
          rescue Runes::ControlFlow::Break
            break
          end

          scope_value = manager.final_output
          break if soft_cap && managers.length >= soft_cap
        end

        Output.new(managers)
      end

      private

      def workflow_context
        execution_manager.workflow_context
      end

      def monotonic
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      # The explicit config cap wins; otherwise the safety-net default unless
      # the rune opted out (`no_iteration_limit!`) or the operator disabled it
      # with RUNES_REPEAT_MAX_ITERATIONS=0.
      def default_max_iterations
        return nil if @config.unlimited_iterations?

        raw = ENV[ENV_MAX_ITERATIONS]
        return DEFAULT_MAX_ITERATIONS if raw.nil? || raw.to_s.strip.empty?

        value = Integer(raw)
        value.positive? ? value : nil
      rescue ArgumentError, TypeError
        DEFAULT_MAX_ITERATIONS
      end
    end
  end
end
