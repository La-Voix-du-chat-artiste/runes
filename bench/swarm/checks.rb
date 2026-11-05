# frozen_string_literal: true

module Runes
  module Bench
    module Swarm
      # The benchmark's mechanical verifier.
      #
      # This is intentionally independent from Runes::Orchestration::Guards:
      # guards decide whether the conductor may accept an artifact; these
      # checks decide whether a case passed. A benchmark that reused the
      # conductor's verifier would grade its own homework.
      class Checks
        ABSTENTION = /
          non\s+document[ée]s?|pas\s+document[ée]s?|not\s+documented|
          introuvable|aucun|absente?|non\s+mentionn[ée]s?|pas\s+mentionn[ée]s?|
          n'est\s+pas\s+explicitement|non\s+pr[ée]sente?|pas\s+pr[ée]sente?|
          je\s+ne\s+peux\s+pas|impossible|cannot|unable
        /ix

        KINDS = %w[cite match forbid field abstain].freeze

        def self.evaluate(answer, checks, gold: nil)
          new(answer, checks, gold: gold).results
        end

        def self.passed?(results)
          Array(results).all? { |result| result[:pass] }
        end

        def self.abstains?(answer)
          answer.to_s.match?(ABSTENTION)
        end

        def initialize(answer, checks, gold: nil)
          @answer = answer.to_s
          @checks = checks || {}
          @gold = gold || {}
        end

        def results
          out = []
          Array(fetch('must_cite')).each do |citation|
            out << result('cite', "cite #{citation}",
                          @answer.downcase.include?(citation.to_s.downcase))
          end
          Array(fetch('must_match')).each do |pattern|
            out << regex_result('match', "match /#{pattern}/i", pattern, should_match: true)
          end
          Array(fetch('must_not_match')).each do |pattern|
            out << regex_result('forbid', "forbid /#{pattern}/i", pattern, should_match: false)
          end
          if fetch('must_abstain')
            out << result('abstain', 'answer abstains', self.class.abstains?(@answer))
          end
          field = fetch('field')
          unless field.nil?
            expected = @gold.is_a?(Hash) ? (@gold[field] || @gold[field.to_s]) : nil
            out << result('field', "field #{field}", expected.nil? || @answer.include?(expected.to_s))
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
