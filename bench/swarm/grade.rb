# frozen_string_literal: true

require_relative 'checks'

module Runes
  module Bench
    module Swarm
      # Grade one benchmark row against the case's expected decision and shape.
      #
      # The grading is intentionally independent from the conductor. The
      # conductor decides whether an artifact may be accepted; this module
      # decides whether the run answered the benchmark question. A mismatch is
      # recorded, never repaired.
      module Grade
        module_function

        SHAPE_ALIASES = {
          'answer-lite' => 'answer_lite',
          'answer_lite' => 'answer_lite',
          'answer-full' => 'answer_full',
          'answer_full' => 'answer_full',
          'decide' => 'decide',
          'see' => 'see',
          'hear' => 'hear',
          'watch' => 'watch',
          'escalate' => 'escalate'
        }.freeze

        def shape(value)
          return nil if value.nil?

          text = value.to_s.strip.downcase.tr('-', '_')
          SHAPE_ALIASES[text] || text
        end

        def decision_status(value)
          return nil if value.nil?
          return value.to_s if value.is_a?(String) || value.is_a?(Symbol)

          hash = value.respond_to?(:to_h) ? value.to_h : nil
          return nil if hash.nil?

          hash['status'] || hash[:status] || hash['decision'] || hash[:decision]
        end

        def decision_reason(value)
          return nil if value.nil?

          hash = value.respond_to?(:to_h) ? value.to_h : nil
          return nil if hash.nil?

          hash['reason_code'] || hash[:reason_code] || hash['reason'] || hash[:reason]
        end

        # The legacy control has no envelope. Its decision is inferred from the
        # artifact and labelled `inferred: true` in the report.
        def infer_decision(final)
          text = final.to_s
          return 'decline' if text.strip.empty?

          'accept'
        end

        def abstains?(final)
          Checks.abstains?(final)
        end

        def grade(spec:, decision: nil, shape: nil, final: nil, checks: nil,
                  inferred: false)
          expected_decision = (spec['expected_decision'] || 'accept').to_s
          expected_reason = spec['expected_reason']&.to_s
          expected_shape = self.shape(spec['expected_shape'])

          actual_decision = decision_status(decision)
          actual_decision = infer_decision(final) if actual_decision.nil? || actual_decision.to_s.empty?
          actual_reason = decision_reason(decision)
          actual_shape = self.shape(shape)
          results = checks || []

          decision_ok = actual_decision.to_s == expected_decision
          reason_ok = expected_reason.nil? || actual_reason.to_s == expected_reason
          shape_ok = expected_shape.nil? ? nil : actual_shape == expected_shape
          checks_ok = Checks.passed?(results)

          {
            expected_decision: expected_decision,
            expected_reason: expected_reason,
            expected_shape: expected_shape,
            decision: actual_decision.to_s,
            reason: actual_reason&.to_s,
            shape: actual_shape,
            decision_ok: decision_ok,
            reason_ok: reason_ok,
            shape_ok: shape_ok,
            checks_ok: checks_ok,
            case_pass: checks_ok && decision_ok && reason_ok,
            abstain: abstains?(final),
            inferred: inferred ? true : false
          }
        end
      end
    end
  end
end
