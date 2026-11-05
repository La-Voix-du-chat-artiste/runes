# frozen_string_literal: true

module Runes
  module Bench
    module Cumulative
      # The benchmark's mechanical verifier. It is intentionally independent
      # from Runes::Orchestration::Guards: guards decide whether a candidate
      # may be accepted, checks decide whether a case passed. The same checks
      # drive the adaptive repair path through a small adapter in runner.rb.
      class Checks
        KINDS = %w[cite match forbid].freeze

        def self.evaluate(answer, checks)
          new(answer, checks).results
        end

        def self.passed?(results)
          Array(results).all? { |result| result[:pass] }
        end

        def initialize(answer, checks)
          @answer = answer.to_s
          @checks = checks || {}
        end

        def results
          out = []
          Array(fetch('must_cite')).each do |citation|
            out << result('cite', "cite #{citation}", @answer.downcase.include?(citation.to_s.downcase))
          end
          Array(fetch('must_match')).each do |pattern|
            out << regex_result('match', "match /#{pattern}/i", pattern, should_match: true)
          end
          Array(fetch('must_not_match')).each do |pattern|
            out << regex_result('forbid', "forbid /#{pattern}/i", pattern, should_match: false)
          end
          out
        end

        def passed?
          self.class.passed?(results)
        end

        private

        def fetch(key)
          @checks[key] || @checks[key.to_sym]
        end

        def regex_result(kind, name, pattern, should_match:)
          regex = Regexp.new(pattern.to_s, Regexp::IGNORECASE)
          matched = @answer.match?(regex)
          result(kind, name, should_match ? matched : !matched)
        rescue RegexpError => e
          result(kind, name, false, error: "invalid regex: #{e.message}")
        end

        def result(kind, name, pass, error: nil)
          { kind: kind, name: name, pass: !!pass, error: error }.compact
        end
      end
    end
  end
end
