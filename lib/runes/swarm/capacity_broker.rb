# frozen_string_literal: true

require_relative 'decision'

module Runes
  module Swarm
    # Authorize a manifest for a task before the conductor calls it.
    #
    # This is a pure function of its inputs: it never calls a model and never
    # writes the ledger. The conductor records the returned Decision, which is
    # why an `accept` carries a control-plane body rather than a model answer.
    class CapacityBroker
      AUTHORIZATION_BODY = 'authorized'

      attr_reader :max_calls, :max_wall_s

      def initialize(max_calls: 1, max_wall_s: nil)
        @max_calls = positive_integer!(max_calls, :max_calls)
        @max_wall_s = max_wall_s.nil? ? nil : positive_number!(max_wall_s, :max_wall_s)
        freeze
      end

      def authorize(manifest:, task: {}, evidence: nil, calls_used: 0, elapsed_s: 0.0)
        return decline(:no_route, 'no manifest is assigned to this role') if manifest.nil?

        if calls_used.to_i >= max_calls
          return decline(:budget_exhausted, "the call budget is exhausted (#{calls_used}/#{max_calls})")
        end

        if max_wall_s && elapsed_s.to_f >= max_wall_s
          return decline(:budget_exhausted, "the wall-clock budget is exhausted (#{elapsed_s}s/#{max_wall_s}s)")
        end

        unsupported = unsupported_modalities(manifest, task)
        unless unsupported.empty?
          return decline(:out_of_modality,
                         "role #{manifest.role} cannot consume #{unsupported.map(&:to_s).join(', ')}; " \
                         "allowed: #{manifest.family.modalities.map(&:to_s).join(', ')}")
        end

        if requires_evidence?(manifest, task) && empty_evidence?(evidence)
          return decline(:missing_evidence, 'the task requires evidence but none was supplied')
        end

        missing = manifest.capacity.missing(required_capabilities(task))
        unless missing.empty?
          return decline(:out_of_capacity, "missing required capabilities: #{missing.map(&:to_s).join(', ')}")
        end

        band = calibration_band(task)
        return band unless band.nil?

        accept
      end

      private

      def accept
        Decision.new(
          status: :accept,
          reason_code: :ok,
          body: AUTHORIZATION_BODY,
          message: 'role authorized'
        )
      end

      def decline(reason_code, message)
        Decision.new(status: :decline, reason_code: reason_code, message: message)
      end

      def requires_evidence?(manifest, task)
        manifest.requires_evidence? || fetch(task, :evidence).to_s == 'required'
      end

      def empty_evidence?(evidence)
        return true if evidence.nil?
        return evidence.strip.empty? if evidence.is_a?(String)
        return evidence.empty? if evidence.respond_to?(:empty?)

        false
      end

      def required_capabilities(task)
        Array(fetch(task, :required)).map(&:to_sym).uniq
      end

      def unsupported_modalities(manifest, task)
        requested = Array(fetch(task, :modality) || fetch(task, :modalities))
        return [] if requested.empty?

        requested.map { |entry| entry.to_s.to_sym }.uniq - manifest.family.modalities
      end

      # The judge returns probabilities; the broker applies the decline band
      # before a role is called. A missing or non-numeric score is not a
      # decline here: the conductor records an unvalidated calibration gate.
      def calibration_band(task)
        scores = fetch(task, :calibration)
        return nil unless scores.is_a?(Hash)

        support = numeric(fetch(scores, :support))
        contradiction = numeric(fetch(scores, :contradiction))

        if !support.nil? && support < 0.30
          return decline(:low_support, "calibrated support #{support} is below 0.30")
        end
        if !contradiction.nil? && contradiction >= 0.50
          return decline(:low_support, "calibrated contradiction #{contradiction} is at or above 0.50")
        end

        nil
      end

      def numeric(value)
        return nil if value.nil?
        return value.to_f if value.is_a?(Numeric)
        return value.to_f if value.to_s.strip.match?(/\A-?\d+(?:\.\d+)?\z/)

        nil
      end

      def fetch(hash, key)
        return nil unless hash.is_a?(Hash)

        hash[key] || hash[key.to_s]
      end

      def positive_integer!(value, field)
        unless value.is_a?(Integer) && value.positive?
          raise ArgumentError, "capacity broker: #{field} must be a positive Integer, got #{value.inspect}"
        end

        value
      end

      def positive_number!(value, field)
        number = value.to_f
        unless number.positive?
          raise ArgumentError, "capacity broker: #{field} must be positive, got #{value.inspect}"
        end

        number
      end
    end
  end
end
