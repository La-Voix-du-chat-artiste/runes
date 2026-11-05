# frozen_string_literal: true

module Runes
  module Bench
    module Swarm
      # Pure metric functions for the benchmark report.
      #
      # Every denominator is explicit. An infra row is counted but never enters
      # an accuracy denominator; a nil metric is `n/a`, not a fabricated zero.
      module Metrics
        module_function

        def ece(pairs, bins: 10)
          values = normalize_pairs(pairs)
          return nil if values.empty?

          buckets = Array.new(bins) { [] }
          values.each do |confidence, correct|
            index = [(confidence * bins).floor, bins - 1].min
            index = 0 if index.negative?
            buckets[index] << [confidence, correct]
          end

          total = values.size.to_f
          buckets.each_with_index.sum do |bucket, index|
            next 0.0 if bucket.empty?

            average = bucket.sum { |confidence, _| confidence } / bucket.size
            accuracy = bucket.count { |_, correct| correct } / bucket.size.to_f
            (bucket.size / total) * (accuracy - average).abs
          end
        end

        def brier(pairs)
          values = normalize_pairs(pairs)
          return nil if values.empty?

          values.sum { |confidence, correct| (confidence - (correct ? 1.0 : 0.0))**2 } / values.size
        end

        def normalize_pairs(pairs)
          Array(pairs).filter_map do |entry|
            confidence, correct =
              if entry.is_a?(Array)
                [entry[0], entry[1]]
              elsif entry.is_a?(Hash)
                [value(entry, :confidence), value(entry, :correct)]
              end
            next if confidence.nil? || correct.nil?

            confidence = [[confidence.to_f, 0.0].max, 1.0].min
            [confidence, !!correct]
          end
        end

        def rate(numerator, denominator)
          return nil if denominator.to_i.zero?

          numerator.to_f / denominator.to_f
        end

        def mean(values)
          list = Array(values).compact.map(&:to_f)
          return nil if list.empty?

          list.sum / list.size
        end

        def accuracy(rows, key)
          values = Array(rows).map { |row| row[key] }.compact
          return nil if values.empty?

          rate(values.count { |value| value == true }, values.size)
        end

        def decline_metrics(rows)
          graded = Array(rows).reject { |row| truthy(row, :infra) }
          expected = graded.select { |row| text(row, :expected_decision) == 'decline' }
          predicted = graded.select { |row| text(row, :decision) == 'decline' }
          true_declines = expected.select { |row| text(row, :decision) == 'decline' }
          answerable = graded.reject { |row| text(row, :expected_decision) == 'decline' }
          false_answers = expected.count do |row|
            text(row, :decision) == 'accept' && !text(row, :final).strip.empty?
          end
          over_declines = answerable.count { |row| text(row, :decision) == 'decline' }

          {
            expected_declines: expected.size,
            predicted_declines: predicted.size,
            true_declines: true_declines.size,
            decline_precision: rate(true_declines.size, predicted.size),
            decline_recall: rate(true_declines.size, expected.size),
            false_answer_rate: rate(false_answers, expected.size),
            false_answers: false_answers,
            over_decline_rate: rate(over_declines, answerable.size),
            over_declines: over_declines
          }
        end

        def checkpoint_stats(rows)
          checkpoints = Array(rows).reject { |row| truthy(row, :infra) }
                                   .flat_map { |row| Array(value(row, :checkpoints)) }
          passed = checkpoints.count { |checkpoint| truthy(checkpoint, :passed) }
          {
            total: checkpoints.size,
            passed: passed,
            pass_rate: rate(passed, checkpoints.size),
            unvalidated_hops: Array(rows).sum { |row| value(row, :unvalidated_hops).to_i },
            first_failure_gates: first_failure_distribution(rows)
          }
        end

        def first_failure_distribution(rows)
          Array(rows).each_with_object(Hash.new(0)) do |row, out|
            gate = first_failure_gate(row)
            out[gate.to_s] += 1 unless gate.nil? || truthy(row, :infra)
          end.sort.to_h
        end

        def first_failure_gate(row)
          Array(value(row, :checkpoints)).each do |checkpoint|
            next unless checkpoint_failed?(checkpoint)

            gates = value(checkpoint, :gates) || {}
            gates.each do |gate, status|
              return gate if status.to_s == 'fail'
            end
          end
          nil
        end

        def selection_quality(rows)
          accuracy(Array(rows).reject { |row| truthy(row, :infra) }, :selection_ok)
        end

        def proposal_divergence(rows)
          accuracy(Array(rows).reject { |row| truthy(row, :infra) }, :divergence)
        end

        def perception_fidelity(rows)
          accuracy(Array(rows).reject { |row| truthy(row, :infra) }, :perception_ok)
        end

        def calibration_pairs(rows, phase: nil)
          Array(rows).reject { |row| truthy(row, :infra) }
                     .flat_map { |row| Array(value(row, :calibration)) }
                     .select do |entry|
                       phase.nil? || value(entry, :phase).to_s == phase.to_s
                     end
                     .filter_map do |entry|
                       confidence = value(entry, :confidence)
                       correct = value(entry, :correct)
                       next if confidence.nil? || correct.nil?

                       [confidence.to_f, !!correct]
                     end
        end

        def percent(value)
          return 'n/a' if value.nil?

          format('%.1f%%', value * 100.0)
        end

        def number(value, digits: 3)
          return 'n/a' if value.nil?

          format("%.#{digits}f", value)
        end

        def checkpoint_failed?(checkpoint)
          failed = value(checkpoint, :passed)
          return !failed if [true, false].include?(failed)

          gates = value(checkpoint, :gates) || {}
          gates.any? { |_gate, status| status.to_s == 'fail' }
        end

        def value(entry, key)
          return nil unless entry.is_a?(Hash)
          return entry[key] if entry.key?(key)
          return entry[key.to_s] if entry.key?(key.to_s)

          nil
        end

        def text(entry, key)
          value(entry, key).to_s
        end

        def truthy(entry, key)
          value(entry, key) ? true : false
        end
      end
    end
  end
end
