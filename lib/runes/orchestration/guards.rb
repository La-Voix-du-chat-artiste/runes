# frozen_string_literal: true

require_relative '../core/section_parser'
require_relative '../json_facade'
require_relative 'violation'

module Runes
  module Orchestration
    # Code-first verification of a model artifact.
    #
    # The benchmark's mechanical checks are accepted as an optional `checks`
    # hash (`must_cite`, `must_match`, `must_not_match`). The domain guards
    # (artifact, citations, unresolved room, numeric grounding, truncation,
    # no-progress) run even when no benchmark checks are supplied.
    class Guards
      ABSTENTION = /
        non\s+document[ée]s?|pas\s+document[ée]s?|not\s+documented|
        introuvable|aucun|absente?|non\s+mentionn[ée]s?|pas\s+mentionn[ée]s?|
        n'est\s+pas\s+explicitement|non\s+pr[ée]sente?|pas\s+pr[ée]sente?
      /ix

      NUMBER_UNIT = /
        (?<![\w.])(\d+(?:[.,]\d+)?)\s*
        (m[²2³3]?|cm|mm|km|litres?|l\/s|degr[ée]s?|°c|personnes?|pouces?|inch|″|")
      /ix

      TERMINAL = /[.!?…]\s*\z/

      def initialize(task: nil, evidence: nil, checks: nil, limits: {})
        @task = task.to_s
        @evidence = evidence
        @checks = checks || {}
        @limits = limits || {}
      end

      # Accept both `guards.check(text)` and the callable verifier shape used
      # by Cumulative (`verifier.call(text, evidence:, task:, receipt:)`).
      def call(artifact, evidence: nil, task: nil, receipt: nil)
        check(artifact, receipt: receipt)
      end

      def check(artifact, receipt: nil)
        text = artifact.to_s
        violations = []
        violations.concat(status_guard(receipt))
        violations.concat(artifact_guard(text))
        violations.concat(truncation_guard(text, receipt))
        violations.concat(citation_guard(text))
        violations.concat(room_guard(text))
        violations.concat(phrase_guard(text))
        violations.concat(numeric_guard(text))
        violations.concat(no_progress_guard(receipt))
        violations
      end

      private

      def artifact_guard(text)
        stripped = text.strip
        return [error('artifact_missing', 'the artifact is empty')] if stripped.empty?

        min = (@limits[:min_chars] || 8).to_i
        if stripped.length < min
          return [error('artifact_too_short', "the artifact is shorter than #{min} characters")]
        end
        if stripped.match?(/\ACitations?\s*:[^\n]*\z/i)
          return [error('artifact_missing', 'the artifact is only a citation line')]
        end
        if stripped.match?(/\A\{.*\}\z/m) && stripped.match?(/"(?:tool|args|tool_calls)"\s*:/)
          return [error('artifact_invalid', 'the artifact is a raw tool-call payload, not an answer')]
        end

        []
      end

      def status_guard(receipt)
        status = receipt_value(receipt, :status)
        case status.to_s
        when 'infra', 'error'
          [error('model_error', "the model call ended with status #{status}")]
        when 'empty_stop'
          [error('artifact_missing', 'the model stopped without producing an artifact')]
        else
          []
        end
      end

      def truncation_guard(text, receipt)
        out = []
        finish = receipt_value(receipt, :finish_reason)
        status = receipt_value(receipt, :status)
        if finish.to_s == 'length' || status.to_s == 'truncated'
          out << error('truncated', 'the model hit its output cap before finishing')
        end

        cap = @limits[:max_output_bytes]
        if cap && text.bytesize >= cap.to_i
          out << error('truncated', "the artifact reached the #{cap}-byte output cap")
        end

        stripped = text.strip
        if stripped.length > 80 && !stripped.match?(TERMINAL) && !stripped.match?(/Citations?\s*:/i)
          out << warn('truncated_suspect', 'the artifact does not end with terminal punctuation')
        end
        out
      end

      def citation_guard(text)
        required = check_values(:must_cite).map(&:to_s).reject(&:empty?)
        out = []
        required.each do |token|
          next if text.downcase.include?(token.downcase)

          out << error('citation_missing', "required citation #{token.inspect} is absent")
        end

        parsed = Runes::Core::SectionParser.new.parse(text)
        citations = parsed[:citations]
        has_line = text.match?(/Citations?\s*:/i)
        if required.any? && !has_line
          out << error('citation_missing', 'the answer has no Citations: line')
        end

        known = citation_hints + required
        citations.each do |token|
          next if token.empty?

          matched = known.any? do |hint|
            h = hint.to_s.downcase
            t = token.downcase
            !h.empty? && (h.include?(t) || t.include?(h))
          end
          out << error('citation_unknown', "citation #{token.inspect} is not in the evidence") unless matched
        end
        out
      end

      def room_guard(text)
        out = []
        room_entries.each do |entry|
          result = fetch_any(entry, :result) || {}
          status = fetch_any(result, :status).to_s
          next if status.empty? || status == 'resolved'

          next if abstention?(text)

          candidates = Array(fetch_any(result, :candidates)).map do |candidate|
            fetch_any(candidate, :chapter) || fetch_any(candidate, :book)
          end.compact.map(&:to_s)
          detail = candidates.empty? ? status : "#{status}: #{candidates.join(', ')}"
          out << error('room_unresolved_asserted',
                       "the room resolution is #{status}, but the answer does not abstain (#{detail})")
        end
        out
      end

      def phrase_guard(text)
        out = []
        check_values(:must_match).each do |pattern|
          regex = compile(pattern)
          if regex.nil?
            out << error('phrase_invalid', "invalid must_match pattern #{pattern.inspect}")
          elsif !text.match?(regex)
            out << error('phrase_missing', "required pattern /#{pattern}/i is absent")
          end
        end
        check_values(:must_not_match).each do |pattern|
          regex = compile(pattern)
          if regex.nil?
            out << error('phrase_invalid', "invalid must_not_match pattern #{pattern.inspect}")
          elsif text.match?(regex)
            out << error('phrase_forbidden', "forbidden pattern /#{pattern}/i is present")
          end
        end
        out
      end

      def numeric_guard(text)
        evidence_text = all_evidence_text
        out = []
        text.scan(NUMBER_UNIT) do |number, unit|
          normalized = number.tr(',', '.')
          next if evidence_text.include?(number) || evidence_text.include?(normalized)

          out << warn('number_ungrounded', "number #{number} #{unit} is not present in the evidence")
        end
        out
      end

      def no_progress_guard(receipt)
        before = receipt_value(receipt, :previous_sha)
        after = receipt_value(receipt, :artifact_sha)
        return [] if before.nil? || after.nil? || before.to_s != after.to_s

        [error('no_progress', 'the repair produced the same artifact as the draft')]
      end

      # "Citations: aucune" is not an abstention: it says there is nothing to
      # cite, not that the requested fact is undocumented. Judge the answer
      # body, with citation lines removed.
      def abstention?(text)
        parsed = Runes::Core::SectionParser.new.parse(text)
        body = parsed[:answer].to_s.gsub(/Citations?\s*:.*$/i, '')
        body.match?(ABSTENTION)
      end

      def check_values(key)
        value = @checks[key] || @checks[key.to_s]
        Array(value).map(&:to_s)
      end

      def compile(pattern)
        Regexp.new(pattern.to_s, Regexp::IGNORECASE)
      rescue RegexpError
        nil
      end

      def room_entries
        entries.select { |entry| fetch_any(entry, :tool).to_s == 'resolve_room' }
      end

      def citation_hints
        @citation_hints ||= begin
          out = []
          entries.each do |entry|
            result = fetch_any(entry, :result) || {}
            out.concat(Array(fetch_any(result, :citation_hints)).map(&:to_s))
            single = fetch_any(result, :citation)
            out << single.to_s unless single.nil?
            Array(fetch_any(result, :results)).each do |row|
              citation = fetch_any(row, :citation)
              out << citation.to_s unless citation.nil?
            end
          end
          out.reject(&:empty?).uniq
        end
      end

      def entries
        @entries ||= begin
          list = @evidence.is_a?(Array) ? @evidence : [@evidence]
          list.compact.select { |entry| entry.is_a?(Hash) }
        end
      end

      def all_evidence_text
        @all_evidence_text ||= begin
          Runes::Json.generate(@evidence)
        rescue StandardError
          @evidence.inspect
        end
      end

      def fetch_any(hash, key)
        return nil unless hash.is_a?(Hash)

        hash[key] || hash[key.to_s]
      end

      def error(code, message, detail: nil)
        Violation.new(code: code, message: message, severity: :error, detail: detail)
      end

      def warn(code, message, detail: nil)
        Violation.new(code: code, message: message, severity: :warn, detail: detail)
      end

      def receipt_value(receipt, key)
        return nil if receipt.nil?
        return receipt[key] if receipt.is_a?(Hash) && receipt.key?(key)
        return receipt[key.to_s] if receipt.is_a?(Hash) && receipt.key?(key.to_s)
        return receipt.public_send(key) if receipt.respond_to?(key)

        nil
      end
    end
  end
end
