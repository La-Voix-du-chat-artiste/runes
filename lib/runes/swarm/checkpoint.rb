# frozen_string_literal: true

require_relative 'identity'
require_relative '../orchestration/violation'

module Runes
  module Swarm
    # One supervised micro-step.
    #
    # The conductor does not trust a 1.7B model to carry a plan. It calls one
    # role, records every gate in order, and only then decides what happens
    # next. This object is the record; it never runs a check itself.
    #
    # A checkpoint always covers the whole `GATES` list. A gate that does not
    # apply is `:skip`, never absent: an absent gate would be an unvalidated
    # hop.
    class Checkpoint
      class Invalid < ArgumentError; end

      GATES = %i[
        call envelope identity capacity decision body schema modality provenance
        verifier calibration progress budget route
      ].freeze

      STATUSES = %i[pass fail skip].freeze

      attr_reader :step, :role, :agent_id, :gates, :violations

      def initialize(step:, role:, gates:, agent_id: nil, violations: [])
        @step = step!(step)
        @role = role!(role)
        @agent_id = agent_id.nil? ? nil : agent_id!(agent_id)
        @gates = gates!(gates)
        @violations = violations!(violations)
        freeze
      end

      # A checkpoint passes only when no gate failed. `skip` is allowed.
      def passed?
        failed_gates.empty?
      end

      def failed_gates
        GATES.select { |gate| @gates[gate] == :fail }
      end

      def skipped_gates
        GATES.select { |gate| @gates[gate] == :skip }
      end

      def status_for(gate)
        @gates[gate.to_s.to_sym]
      end

      def to_h
        {
          'step' => step,
          'role' => role.to_s,
          'agent_id' => agent_id,
          'gates' => gates.each_with_object({}) { |(gate, status), out| out[gate.to_s] = status.to_s },
          'violations' => violations.map { |violation| violation_hash(violation) },
          'passed' => passed?,
          'failed_gates' => failed_gates.map(&:to_s)
        }
      end

      def inspect
        "#<#{self.class.name} step=#{step} role=#{role} passed=#{passed?} failed=#{failed_gates.inspect}>"
      end

      private

      def step!(value)
        unless value.is_a?(Integer) && value.positive?
          raise Invalid, "checkpoint: step must be a positive Integer, got #{value.inspect}"
        end

        value
      end

      def role!(value)
        role = value.to_s.to_sym
        unless Identity::ROLES.include?(role)
          raise Invalid, "checkpoint: unknown role #{value.inspect} (known: #{Identity::ROLES.join(', ')})"
        end

        role
      end

      def agent_id!(value)
        unless value.is_a?(String) && value.match?(Identity::AGENT_ID)
          raise Invalid, "checkpoint: invalid agent_id #{value.inspect}"
        end

        value.dup.freeze
      end

      def gates!(value)
        raise Invalid, "checkpoint: gates must be a Hash, got #{value.class}" unless value.is_a?(Hash)

        normalized = {}
        value.each do |key, status|
          gate = key.to_s.to_sym
          raise Invalid, "checkpoint: unknown gate #{key.inspect}" unless GATES.include?(gate)

          normalized[gate] = status!(status, gate)
        end

        missing = GATES - normalized.keys
        unless missing.empty?
          raise Invalid, "checkpoint: missing gates #{missing.inspect} (use :skip when a gate does not apply)"
        end

        GATES.each_with_object({}) { |gate, out| out[gate] = normalized.fetch(gate) }.freeze
      end

      def status!(value, gate)
        status = value.to_s.to_sym
        unless STATUSES.include?(status)
          raise Invalid, "checkpoint: gate #{gate.inspect} has unknown status #{value.inspect}"
        end

        status
      end

      def violations!(value)
        raise Invalid, "checkpoint: violations must be an Array, got #{value.class}" unless value.is_a?(Array)

        value.dup.freeze
      end

      def violation_hash(violation)
        hash = violation.respond_to?(:to_h) ? violation.to_h : { 'message' => violation.to_s }
        hash.each_with_object({}) { |(key, value), out| out[key.to_s] = value }
      end
    end
  end
end
