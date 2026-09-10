# frozen_string_literal: true

require_relative "../rune"
require_relative "../workflow/system_rune"

module Runes
  module Plugins
    # The `call` system rune: run a named `execute(:scope)` once with a value
    # and index passed in. Use `from(call!(...))` to read the scope's final
    # output.
    class Call < Runes::SystemRune
      plugin :call, description: "Invoke a named execute(:scope) block"

      class Config < Runes::Cog::Config; end

      class Input < Runes::Cog::Input
        attr_accessor :value, :index

        def initialize
          super
          @index = 0
        end

        def validate!
          raise InvalidInputError, "'value' is required" if value.nil? && !coerce_ran?
        end

        def coerce(input_return_value)
          super
          @value = input_return_value unless Runes.present?(@value)
        end
      end

      # Opaque handle on the called scope; `from` knows how to read it.
      class Output < Runes::Cog::Output
        attr_reader :execution_manager

        def initialize(execution_manager)
          super()
          @execution_manager = execution_manager
        end

        def final_output
          execution_manager.final_output
        end

        def raw_text
          final_output.to_s
        end
      end

      protected

      def execute(input)
        raise Runes::ExecutionManager::ExecutionScopeNotSpecifiedError, "run: is required" if run.nil?

        manager = execution_manager.build_scope_manager(run, input.value, input.index)
        begin
          manager.run!
        rescue Runes::ControlFlow::Next, Runes::ControlFlow::Break
          # Treat `break!` like `next!` inside a call: end the scope and return
          # whatever it produced.
        end
        Output.new(manager)
      end
    end
  end
end
