# frozen_string_literal: true

require_relative '../core/section_parser'
require_relative '../orchestration/violation'
require_relative 'envelope'
require_relative 'capacity'
require_relative 'decision'

module Runes
  module Swarm
    # Compare a parsed envelope with the assigned manifest.
    #
    # The guard is deliberately strict: the model echoes the identity and
    # capacity it was given, and any difference is a typed error. It never
    # repairs an envelope; the conductor records the violation and stops the
    # step.
    class ContractGuard
      TOOL_CALL = /\A\s*\{.*"(?:tool|tool_calls|args|function)"\s*:/m
      CITATIONS = /Citations?\s*:/i
      CRITIQUE_SECTIONS = %w[
        CRITIQUE CLAIMS UNSUPPORTED VERDICT VIOLATIONS ISSUES FINDINGS
      ].freeze

      attr_reader :manifest, :required

      def initialize(manifest:, required: [])
        raise ArgumentError, 'contract guard: manifest is required' if manifest.nil?

        @manifest = manifest
        @required = Array(required).map(&:to_sym).uniq.freeze
        freeze
      end

      def check(model_text)
        check_envelope(Envelope.parse(model_text))
      end

      def check_envelope(envelope)
        return [error('contract_missing', 'the model emitted no contract envelope')] if envelope.nil? || envelope.empty?

        out = []
        out.concat(identity_violations(envelope))
        out.concat(capacity_violations(envelope))
        out.concat(decision_violations(envelope))
        out.concat(schema_violations(envelope))
        out.concat(forbidden_action_violations(envelope))
        out
      end

      # Check the typed artifact behind a stamped envelope. Perception roles
      # must emit resolvable anchors; a judge must stay inside its calibrated
      # band; no role may consume a modality its family does not accept.
      def check_artifact(artifact, modality: nil)
        out = []
        out.concat(modality_violations(artifact, modality))
        out.concat(perception_violations(artifact))
        out.concat(calibration_violations(artifact))
        out
      end

      private

      def modality_violations(artifact, modality)
        claimed = modality || artifact_modality(artifact)
        return [] if claimed.nil?

        requested = Array(claimed).map { |entry| entry.to_s.to_sym }.uniq
        allowed = manifest.family.modalities
        unsupported = requested - allowed
        return [] if unsupported.empty?

        [error('modality_mismatch',
               "role #{manifest.role} (#{manifest.base_model}) cannot consume " \
               "#{unsupported.map(&:to_s).join(', ')}; allowed: #{allowed.map(&:to_s).join(', ')}",
               detail: unsupported.map(&:to_s))]
      end

      def perception_violations(artifact)
        return [] unless %i[vision audio omni].include?(manifest.role)

        unless artifact.is_a?(Hash)
          return [error('perception_shape', 'a perception role must emit a perception.v1 object')]
        end

        fields = string_keys(artifact)
        missing = %w[modality source_sha256 anchors] - fields.keys
        unless missing.empty?
          return [error('perception_shape',
                        "perception.v1 is missing #{missing.join(', ')}",
                        detail: missing)]
        end

        anchors = fields['anchors']
        unless anchors.is_a?(Array)
          return [error('perception_shape', 'perception.v1 anchors must be an Array')]
        end

        valid = anchors.reject { |anchor| anchor.nil? || anchor.to_s.strip.empty? }
        return [] unless valid.empty?

        [error('provenance_missing',
               'perception.v1 has no resolvable anchor (page/box/time/frame)')]
      end

      def calibration_violations(artifact)
        return [] unless artifact.is_a?(Hash)

        fields = string_keys(artifact)
        scores = fields['calibration'] || fields['scores']
        return [] unless scores.is_a?(Hash)

        scores = string_keys(scores)
        support = numeric(scores['support'])
        contradiction = numeric(scores['contradiction'])
        return [] if support.nil? && contradiction.nil?

        if !support.nil? && support < 0.30
          return [error('calibration_low',
                        "support #{support} is in the decline band (< 0.30)",
                        detail: ['support'])]
        end
        if !contradiction.nil? && contradiction >= 0.50
          return [error('calibration_low',
                        "contradiction #{contradiction} is in the decline band (>= 0.50)",
                        detail: ['contradiction'])]
        end
        []
      end

      def artifact_modality(artifact)
        return nil unless artifact.is_a?(Hash)

        fields = string_keys(artifact)
        fields['modality'] || fields['modalities']
      end

      def string_keys(hash)
        hash.each_with_object({}) { |(key, value), out| out[key.to_s] = value }
      end

      def numeric(value)
        return nil if value.nil?
        return value.to_f if value.is_a?(Numeric)
        return value.to_f if value.to_s.strip.match?(/\A-?\d+(?:\.\d+)?\z/)

        nil
      end

      def identity_violations(envelope)
        fields = envelope.identity_fields
        return [error('identity_missing', 'the envelope has no IDENTITY block')] if fields.empty?

        expected = {
          'agent_id' => manifest.agent_id,
          'version' => manifest.version,
          'role' => manifest.role.to_s,
          'base_model' => manifest.base_model,
          'adapter_sha256' => manifest.adapter_sha256
        }
        mismatched = expected.reject { |key, value| same?(fields[key], value) }
        return [] if mismatched.empty?

        detail = mismatched.map do |key, value|
          "#{key}: expected #{value.inspect}, got #{fields[key].inspect}"
        end
        [error('identity_mismatch',
               "the echoed identity does not match the manifest (#{detail.join('; ')})",
               detail: detail)]
      end

      def capacity_violations(envelope)
        fields = envelope.capacity_fields
        return [error('capacity_missing', 'the envelope has no CAPACITIES block')] if fields.empty?

        out = []
        can = Array(fields['can']).map(&:to_sym)
        cannot = Array(fields['cannot']).map(&:to_sym)

        out << error('capacity_missing', 'the envelope omits the can list') unless fields.key?('can')
        out << error('capacity_missing', 'the envelope omits the cannot list') unless fields.key?('cannot')

        conflict = can & cannot
        unless conflict.empty?
          out << error('capacity_conflict',
                       "the envelope lists #{conflict.map(&:to_s).join(', ')} in both can and cannot",
                       detail: conflict.map(&:to_s))
        end

        overreach = can - manifest.capacity.can
        unless overreach.empty?
          out << error('capacity_overreach',
                       "the envelope claims capabilities outside the manifest: #{overreach.map(&:to_s).join(', ')}",
                       detail: overreach.map(&:to_s))
        end

        missing = required - can
        unless missing.empty?
          out << error('capacity_missing',
                       "the envelope omits required capabilities: #{missing.map(&:to_s).join(', ')}",
                       detail: missing.map(&:to_s))
        end
        if can.empty? && missing.empty?
          out << error('capacity_missing', 'the envelope declares no capabilities')
        end
        out
      end

      def decision_violations(envelope)
        fields = envelope.decision_fields
        return [error('decision_missing', 'the envelope has no DECISION block')] if fields.empty?

        status = fields['status'].to_s
        unless Decision::STATUSES.map(&:to_s).include?(status)
          return [error('decision_invalid', "unknown decision status #{fields['status'].inspect}")]
        end

        reason = fields['reason_code'].to_s
        unless Decision::REASONS.map(&:to_s).include?(reason)
          return [error('decision_invalid', "unknown reason_code #{fields['reason_code'].inspect}")]
        end

        hop = fields['next_hop']
        if !hop.nil? && !Decision::HOPS.map(&:to_s).include?(hop.to_s)
          return [error('decision_invalid', "unknown next_hop #{hop.inspect}")]
        end

        out = []
        case status
        when 'accept'
          out << error('decision_invalid', 'accept requires reason_code ok') unless reason == 'ok'
          out << error('decision_invalid', 'accept must not carry a next_hop') unless hop.nil?
          out << error('body_missing', 'accept requires a non-empty body') if envelope.body.strip.empty?
        when 'decline'
          out << error('decision_invalid', 'decline requires a non-ok reason_code') if reason == 'ok'
          out << error('body_forbidden', 'decline must not carry a body') unless envelope.body.strip.empty?
        when 'escalate'
          out << error('decision_invalid', 'escalate requires a non-ok reason_code') if reason == 'ok'
          out << error('decision_invalid', 'escalate requires a next_hop') if hop.nil?
          out << error('body_forbidden', 'escalate must not carry a body') unless envelope.body.strip.empty?
        end
        out
      end

      def schema_violations(envelope)
        fields = envelope.capacity_fields
        return [] if fields.empty?

        schema = fields['output_schema'].to_s.strip
        return [error('output_schema_unknown', 'the envelope omits output_schema')] if schema.empty?
        unless Capacity::SCHEMAS.include?(schema)
          return [error('output_schema_unknown', "unknown output_schema #{schema.inspect}")]
        end

        expected = manifest.capacity.output_schema
        return [] if schema == expected

        [error('output_schema_unknown',
               "output_schema #{schema.inspect} does not match the assigned #{expected.inspect}")]
      end

      def forbidden_action_violations(envelope)
        body = envelope.body.to_s
        return [] if body.strip.empty?

        out = []
        if manifest.forbidden_actions.include?(:execute_tools) && body.match?(TOOL_CALL)
          out << error('forbidden_action',
                       'the body is a raw tool-call payload, but this role forbids execute_tools')
        end
        if manifest.role == :critic && body.match?(CITATIONS) && !critique_shape?(body)
          out << error('forbidden_action',
                       'the critic body has a citation line but no critique sections')
        end
        out
      end

      def critique_shape?(body)
        sections = Runes::Core::SectionParser.new.parse(body)[:sections] || {}
        (sections.keys & CRITIQUE_SECTIONS).any?
      end

      def same?(left, right)
        return true if left.nil? && right.nil?

        left.to_s.strip == right.to_s.strip
      end

      def error(code, message, detail: nil)
        Runes::Orchestration::Violation.new(
          code: code,
          message: message,
          severity: :error,
          detail: detail
        )
      end
    end
  end
end
