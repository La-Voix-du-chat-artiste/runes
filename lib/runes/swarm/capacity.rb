# frozen_string_literal: true

module Runes
  module Swarm
    # What a role may and may not do, plus its token and output-shape bounds.
    #
    # `can` is a positive allow-list; `cannot` is mandatory and must be
    # disjoint from it. A capability outside `can` is an overreach even when
    # it is not named in `cannot`; `cannot` exists to make the refusal
    # explicit in the manifest and in the prompt.
    class Capacity
      class Invalid < ArgumentError; end

      SCHEMAS = %w[
        answer.v1 critique.v1 evidence.v1 decision.v1 violations.v1
        plan.v1 proposal.v1 perception.v1 verdict.v1 review.v1
      ].freeze

      FIELDS = %w[
        can cannot max_input_tokens max_output_tokens output_schema
      ].freeze

      attr_reader :can, :cannot, :max_input_tokens, :max_output_tokens, :output_schema

      def self.from_h(hash)
        data = normalize(hash)
        unknown = data.keys - FIELDS
        raise Invalid, "capacity: unknown keys #{unknown.sort.inspect}" unless unknown.empty?

        missing = FIELDS - data.keys
        raise Invalid, "capacity: missing keys #{missing.sort.inspect}" unless missing.empty?

        new(
          can: data.fetch('can'),
          cannot: data.fetch('cannot'),
          max_input_tokens: data.fetch('max_input_tokens'),
          max_output_tokens: data.fetch('max_output_tokens'),
          output_schema: data.fetch('output_schema')
        )
      end

      def self.normalize(hash)
        raise Invalid, "capacity: expected a Hash, got #{hash.class}" unless hash.is_a?(Hash)

        hash.each_with_object({}) { |(key, value), out| out[key.to_s] = value }
      end
      private_class_method :normalize

      def initialize(can:, cannot:, max_input_tokens:, max_output_tokens:, output_schema:)
        @can = capabilities!(can, :can)
        @cannot = capabilities!(cannot, :cannot)
        @max_input_tokens = tokens!(max_input_tokens, :max_input_tokens)
        @max_output_tokens = tokens!(max_output_tokens, :max_output_tokens)
        @output_schema = output_schema.to_s.dup.freeze

        validate!
        freeze
      end

      def allows?(capability)
        can.include?(capability.to_sym)
      end

      def forbids?(capability)
        cannot.include?(capability.to_sym)
      end

      # Capabilities the caller claims but the manifest does not grant.
      def overreach(claimed)
        normalize_capabilities(claimed) - can
      end

      # Required capabilities the manifest does not grant.
      def missing(required)
        normalize_capabilities(required) - can
      end

      # True when every granted capability is also granted by `other`.
      def subset_of?(other)
        unless other.is_a?(Capacity)
          raise Invalid, "capacity: subset_of? expects a Capacity, got #{other.class}"
        end

        (can - other.can).empty?
      end

      def to_h
        {
          'can' => can.map(&:to_s),
          'cannot' => cannot.map(&:to_s),
          'max_input_tokens' => max_input_tokens,
          'max_output_tokens' => max_output_tokens,
          'output_schema' => output_schema
        }
      end

      def ==(other)
        other.is_a?(Capacity) && to_h == other.to_h
      end
      alias eql? ==

      def hash
        to_h.hash
      end

      def inspect
        "#<#{self.class.name} can=#{can.inspect} cannot=#{cannot.inspect} schema=#{output_schema}>"
      end

      private

      def validate!
        raise Invalid, 'capacity: can must not be empty' if can.empty?
        raise Invalid, 'capacity: cannot must not be empty' if cannot.empty?

        overlap = can & cannot
        raise Invalid, "capacity: can and cannot overlap on #{overlap.inspect}" unless overlap.empty?

        unless SCHEMAS.include?(output_schema)
          raise Invalid, "capacity: unknown output_schema #{output_schema.inspect} (known: #{SCHEMAS.join(', ')})"
        end
      end

      def capabilities!(value, field)
        unless value.is_a?(Array)
          raise Invalid, "capacity: #{field} must be an Array, got #{value.class}"
        end
        raise Invalid, "capacity: #{field} must not be empty" if value.empty?

        normalized = value.map do |capability|
          unless capability.is_a?(Symbol) || capability.is_a?(String)
            raise Invalid, "capacity: #{field} entries must be Symbols or Strings, got #{capability.inspect}"
          end
          raise Invalid, "capacity: #{field} contains an empty capability" if capability.to_s.strip.empty?

          capability.to_sym
        end
        normalized.uniq.freeze
      end

      def normalize_capabilities(value)
        Array(value).map(&:to_sym).uniq
      end

      def tokens!(value, field)
        unless value.is_a?(Integer) && !value.negative?
          raise Invalid, "capacity: #{field} must be a non-negative Integer, got #{value.inspect}"
        end

        value
      end
    end
  end
end
