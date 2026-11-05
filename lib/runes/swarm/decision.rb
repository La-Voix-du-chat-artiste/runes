# frozen_string_literal: true

module Runes
  module Swarm
    # A first-class accept / decline / escalate decision.
    #
    # A decline is not an error and is not retried with the same role: it is a
    # typed routing decision. The body rules make the difference mechanical:
    # an accept must carry a body, a decline/escalation must not.
    class Decision
      class Invalid < ArgumentError; end

      STATUSES = %i[accept decline escalate].freeze

      REASONS = %i[
        ok out_of_capacity missing_evidence conflicting_evidence
        unsupported_claim citation_missing context_overflow low_confidence
        needs_frontier needs_human budget_exhausted no_route contract_invalid
        out_of_modality needs_perception needs_vision needs_audio needs_omni
        perception_insufficient low_support proposal_collapse repair_exhausted
        unsafe_request out_of_scope ambiguous_request
      ].freeze

      HOPS = %i[
        scout planner reviewer triage judge vision audio omni ideator answerer
        critic repairer finalizer frontier human
      ].freeze

      FIELDS = %w[status reason_code next_hop message body].freeze

      attr_reader :status, :reason_code, :next_hop, :message, :body

      def self.from_h(hash)
        data = normalize(hash)
        unknown = data.keys - FIELDS
        raise Invalid, "decision: unknown keys #{unknown.sort.inspect}" unless unknown.empty?

        missing = %w[status reason_code] - data.keys
        raise Invalid, "decision: missing keys #{missing.sort.inspect}" unless missing.empty?

        new(
          status: data.fetch('status'),
          reason_code: data.fetch('reason_code'),
          next_hop: data['next_hop'],
          message: data['message'],
          body: data['body']
        )
      end

      def self.normalize(hash)
        raise Invalid, "decision: expected a Hash, got #{hash.class}" unless hash.is_a?(Hash)

        hash.each_with_object({}) { |(key, value), out| out[key.to_s] = value }
      end
      private_class_method :normalize

      def initialize(status:, reason_code:, next_hop: nil, message: nil, body: nil)
        @status = status.to_s.to_sym
        @reason_code = reason_code.to_s.to_sym
        @next_hop = next_hop.nil? ? nil : next_hop.to_s.to_sym
        @message = optional_string!(message, :message)
        @body = optional_string!(body, :body) || ''

        validate!
        freeze
      end

      def accept?
        status == :accept
      end

      def decline?
        status == :decline
      end

      def escalate?
        status == :escalate
      end

      def body_required?
        accept?
      end

      def body_empty?
        body.strip.empty?
      end

      def to_h
        {
          'status' => status.to_s,
          'reason_code' => reason_code.to_s,
          'next_hop' => next_hop&.to_s,
          'message' => message,
          'body' => body
        }
      end

      def ==(other)
        other.is_a?(Decision) && to_h == other.to_h
      end
      alias eql? ==

      def hash
        to_h.hash
      end

      def inspect
        "#<#{self.class.name} status=#{status} reason=#{reason_code} next_hop=#{next_hop.inspect}>"
      end

      private

      def validate!
        unless STATUSES.include?(status)
          raise Invalid, "decision: unknown status #{status.inspect} (known: #{STATUSES.join(', ')})"
        end
        unless REASONS.include?(reason_code)
          raise Invalid, "decision: unknown reason_code #{reason_code.inspect}"
        end
        if !next_hop.nil? && !HOPS.include?(next_hop)
          raise Invalid, "decision: unknown next_hop #{next_hop.inspect} (known: #{HOPS.join(', ')})"
        end

        case status
        when :accept then validate_accept!
        when :decline then validate_decline!
        when :escalate then validate_escalate!
        end
      end

      def validate_accept!
        raise Invalid, 'decision: accept requires reason_code :ok' unless reason_code == :ok
        raise Invalid, 'decision: accept must not carry a next_hop' unless next_hop.nil?
        raise Invalid, 'decision: accept requires a non-empty body' if body_empty?
      end

      def validate_decline!
        raise Invalid, 'decision: decline requires a non-:ok reason_code' if reason_code == :ok
        raise Invalid, 'decision: decline must not carry a body' unless body_empty?
      end

      def validate_escalate!
        raise Invalid, 'decision: escalate requires a non-:ok reason_code' if reason_code == :ok
        raise Invalid, 'decision: escalate must not carry a body' unless body_empty?
        raise Invalid, 'decision: escalate requires a next_hop' if next_hop.nil?
      end

      def optional_string!(value, field)
        return nil if value.nil?
        unless value.is_a?(String)
          raise Invalid, "decision: #{field} must be a String or nil, got #{value.class}"
        end

        value.dup.freeze
      end
    end
  end
end
