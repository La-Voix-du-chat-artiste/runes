# frozen_string_literal: true

require_relative "../rune"
require_relative "../workflow/system_rune"
require_relative "call"

module Runes
  module Plugins
    # The `map` system rune: run a named `execute(:scope)` once per item, in
    # series (the default) or in parallel threads honouring `parallel(n)`.
    class Map < Runes::SystemRune
      plugin :map, description: "Run a scope once per item"

      # Raised when an iteration that did not run is addressed.
      class MapIterationDidNotRunError < Runes::Error; end

      class Config < Runes::Cog::Config
        # `parallel(n)` with n > 0 caps concurrency; n <= 0 means unlimited.
        def parallel(value)
          @values[:parallel] = value.to_i.positive? ? value.to_i : nil
        end

        def parallel!
          @values[:parallel] = nil
        end

        def no_parallel!
          @values[:parallel] = 1
        end

        def validate!
          valid_parallel!
        end

        # nil = unlimited; positive Integer = cap; raises on a negative value.
        def valid_parallel!
          parallel = @values.fetch(:parallel, 1)
          return nil if parallel.nil?
          raise InvalidConfigError, "'parallel' must be >= 0 if specified" if parallel.negative?

          parallel
        end
      end

      class Input < Runes::Cog::Input
        attr_accessor :items, :initial_index

        def initialize
          super
          @items = []
          @initial_index = 0
        end

        def validate!
          raise InvalidInputError, "'items' is required" if items.nil?
          raise InvalidInputError, "'items' must not be empty" if items.empty? && !coerce_ran?
        end

        def coerce(input_return_value)
          super
          return if items && !items.empty?

          @items = input_return_value.respond_to?(:each) ? input_return_value.to_a : Array(input_return_value)
        end
      end

      class Output < Runes::Cog::Output
        attr_reader :execution_managers

        def initialize(execution_managers)
          super()
          @execution_managers = execution_managers
        end

        def iteration?(index)
          !@execution_managers.fetch(index).nil?
        end

        # Returns a call-style handle for use with `from`; raises if the
        # iteration never ran (e.g. after `break!`).
        def iteration(index)
          manager = @execution_managers.fetch(index)
          raise MapIterationDidNotRunError, index if manager.nil?

          Runes::Plugins::Call::Output.new(manager)
        end

        def first
          iteration(0)
        end

        def last
          iteration(-1)
        end

        def raw_text
          @execution_managers.map { |manager| manager&.final_output }.inspect
        end
      end

      protected

      def execute(input)
        max_parallel = @config.valid_parallel!
        max_parallel == 1 ? execute_serial(input) : execute_parallel(input, max_parallel)
      end

      private

      # `next!` moves on to the next item; `break!` stops starting new items.
      # Items that never ran are nil slots in the output.
      def execute_serial(input)
        managers = []
        input.items.each_with_index do |item, index|
          manager = execution_manager.build_scope_manager(run, item, index + input.initial_index)
          managers << manager
          begin
            manager.run!
          rescue Runes::ControlFlow::Next
            # continue with the next item
          rescue Runes::ControlFlow::Break
            break
          end
        end
        managers.fill(nil, managers.length, input.items.length - managers.length)
        Output.new(managers)
      end

      def execute_parallel(input, max_parallel)
        items = input.items
        managers = Array.new(items.length)
        return Output.new(managers) if items.empty?

        errors = []
        errors_mutex = Mutex.new
        stopped = false
        stop_mutex = Mutex.new
        # A fixed pool of workers draining one queue (W5-2): the thread count
        # is bounded by `parallel(n)` regardless of how many items there are.
        worker_count = max_parallel.nil? ? items.length : [max_parallel, items.length].min
        queue = Queue.new
        items.each_with_index { |item, index| queue << [item, index] }
        worker_count.times { queue << :runes_map_stop }

        workers = Array.new(worker_count) do
          Thread.new do
            loop do
              work = queue.pop
              break if work == :runes_map_stop

              item, index = work
              next if stop_mutex.synchronize { stopped }

              run_iteration(input, managers, errors, errors_mutex, item, index) do
                stop_mutex.synchronize { stopped = true }
              end
            end
          end.tap do |thread|
            thread.report_on_exception = false if thread.respond_to?(:report_on_exception=)
          end
        end
        workers.each(&:join)

        raise errors.first if errors.any?

        Output.new(managers)
      end

      def run_iteration(input, managers, errors, errors_mutex, item, index)
        manager = execution_manager.build_scope_manager(run, item, index + input.initial_index)
        managers[index] = manager
        manager.run!
      rescue Runes::ControlFlow::Next
        # This iteration is done; other iterations continue.
      rescue Runes::ControlFlow::Break
        yield
      rescue StandardError => e
        errors_mutex.synchronize { errors << e }
        yield
      end
    end
  end
end
