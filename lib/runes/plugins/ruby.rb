# frozen_string_literal: true

require_relative "../rune"

module Runes
  module Plugins
    # The `ruby` rune: pass any Ruby value through the workflow. The input
    # block's return value (or `my.value = ...`) becomes the output, and the
    # output delegates missing methods to that value so `ruby!(:x).lines`
    # works on a String and `ruby!(:x).foo` works on a Hash key.
    class Ruby < Runes::Rune
      plugin :ruby, description: "Pass a Ruby value through the workflow"

      class Config < Runes::Cog::Config; end

      class Input < Runes::Cog::Input
        attr_accessor :value

        def validate!
          raise InvalidInputError, "'value' is required" if value.nil? && !coerce_ran?
        end

        def coerce(input_return_value)
          super
          @value = input_return_value
        end
      end

      class Output < Runes::Cog::Output
        attr_reader :value

        def initialize(value)
          super()
          @value = value
        end

        def [](key)
          value[key]
        end

        # The canonical text form of any Ruby value (used by the CLI's final
        # output printer and by `WithText`-style consumers).
        def raw_text
          value.to_s
        end

        # `call` on a Proc value calls it; on a Hash value, the first
        # argument is the key whose Proc should be called.
        def call(*args, **kwargs, &blk)
          return value.call(*args, **kwargs, &blk) if value.is_a?(Proc)

          key = args.first
          raise ArgumentError, "call requires a Symbol key on a Hash value" unless key.is_a?(Symbol)

          proc = value[key]
          raise NoMethodError, key unless proc.is_a?(Proc)

          proc.call(*args.drop(1), **kwargs, &blk)
        end

        # 1. delegate to the value, 2. Hash key lookup (calling Procs).
        def method_missing(name, *args, **kwargs, &blk)
          return value.public_send(name, *args, **kwargs, &blk) if value.respond_to?(name, false)
          return super unless value.is_a?(Hash) && value.key?(name)

          stored = value[name]
          if stored.is_a?(Proc)
            stored.call(*args, **kwargs, &blk)
          else
            stored
          end
        end

        def respond_to_missing?(name, include_private = false)
          value.respond_to?(name, false) || (value.is_a?(Hash) && value.key?(name)) || super
        end
      end

      protected

      def execute(input)
        # A ruby rune is arbitrary code inside the harness process: under a
        # policy it must be named explicitly.
        Runes::WorkflowPolicy.authorize!(rune: "ruby", action: :execute, resource: name.to_s,
                                           hint: 'e.g. "ruby": { "execute": ["*"] }')
        Output.new(input.value)
      end
    end
  end
end
