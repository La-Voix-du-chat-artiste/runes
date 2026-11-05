# frozen_string_literal: true

require 'fileutils'
require 'json'

require_relative 'cases'
require_relative 'metrics'

module Runes
  module Bench
    module Swarm
      # Render the benchmark's Markdown + JSON decision record.
      #
      # Two denominators stay visible: graded rows (infra excluded) and all
      # rows. A missing metric is printed as `n/a`, never as a fabricated
      # zero. The report refuses to overwrite an existing path.
      class Report
        class Error < StandardError; end

        SECRET_KEY = /api[_-]?key|authorization|secret|token|password/i
        SECRET_VALUE = /(?:sk-[A-Za-z0-9_-]{8,}|Bearer\s+[A-Za-z0-9._-]+)/i

        attr_reader :meta, :rows, :baseline

        def self.load(path)
          data = JSON.parse(File.read(path))
          rows = Array(data['rows']).map { |row| row.transform_keys(&:to_sym) }
          new(meta: data['meta'] || {}, rows: rows)
        rescue Errno::ENOENT
          raise Error, "baseline report not found: #{path}"
        rescue JSON::ParserError => e
          raise Error, "baseline report is not valid JSON: #{e.message}"
        end

        def initialize(meta:, rows:, baseline: nil)
          @meta = meta || {}
          @rows = Array(rows)
          @baseline = baseline
        end

        def infra_count
          @rows.count { |row| truthy(row, :infra) }
        end

        def graded_rows
          @rows.reject { |row| truthy(row, :infra) }
        end

        def denominator
          {
            rows: @rows.size,
            graded: graded_rows.size,
            infra: infra_count,
            excluded: @rows.size - graded_rows.size,
            cases: @rows.map { |row| value(row, :id).to_s }.reject(&:empty?).uniq.size,
            arms: @rows.map { |row| value(row, :arm).to_s }.reject(&:empty?).uniq.sort
          }
        end

        def summary
          @rows.group_by { |row| value(row, :arm).to_s }.sort.map do |arm, list|
            graded = list.reject { |row| truthy(row, :infra) }
            stats = Metrics.checkpoint_stats(graded)
            decline = Metrics.decline_metrics(graded)
            calibration = Metrics.calibration_pairs(graded)
            calls = graded.flat_map { |row| Array(value(row, :calls)) }
            {
              arm: arm,
              rows: list.size,
              graded: graded.size,
              infra: list.size - graded.size,
              case_pass: graded.count { |row| truthy(row, :case_pass) },
              case_pass_label: "#{graded.count { |row| truthy(row, :case_pass) }}/#{graded.size}",
              checks_passed: graded.sum { |row| value(row, :passed).to_i },
              checks_total: graded.sum { |row| value(row, :total).to_i },
              checks: "#{graded.sum { |row| value(row, :passed).to_i }}/" \
                      "#{graded.sum { |row| value(row, :total).to_i }}",
              shape_accuracy: Metrics.accuracy(graded, :shape_ok),
              perception_fidelity: Metrics.perception_fidelity(graded),
              proposal_divergence: Metrics.proposal_divergence(graded),
              selection_quality: Metrics.selection_quality(graded),
              ece: Metrics.ece(calibration),
              brier: Metrics.brier(calibration),
              decline_precision: decline[:decline_precision],
              decline_recall: decline[:decline_recall],
              false_answer_rate: decline[:false_answer_rate],
              over_decline_rate: decline[:over_decline_rate],
              contract_violations: graded.sum { |row| Array(value(row, :violations)).size },
              checkpoint_pass_rate: stats[:pass_rate],
              checkpoints: stats[:total],
              unvalidated_hops: stats[:unvalidated_hops],
              first_failure_gates: stats[:first_failure_gates],
              calls: calls.size,
              calls_by_role: group_calls(calls, :role),
              calls_by_model: group_calls(calls, :model),
              wall_s: Metrics.mean(graded.map { |row| value(row, :elapsed_s) }),
              cold: graded.count { |row| truthy(row, :cold) },
              warm: graded.count { |row| truthy(row, :warm) },
              peak_memory_mb: Metrics.mean(graded.map { |row| value(row, :peak_memory_mb) }),
              regressions: regressions_for(arm, list),
              statuses: list.group_by { |row| value(row, :status).to_s }.transform_values(&:size)
            }
          end
        end

        # Six families separately, and within each family the arms separately.
        def family_table
          ordered_families.flat_map do |family|
            list = @rows.select { |row| value(row, :family).to_s == family }
            next [] if list.empty?

            list.group_by { |row| value(row, :arm).to_s }.sort.map do |arm, arm_rows|
              graded = arm_rows.reject { |row| truthy(row, :infra) }
              decline = Metrics.decline_metrics(graded)
              {
                family: family,
                arm: arm,
                cases: graded.size,
                infra: arm_rows.size - graded.size,
                case_pass: "#{graded.count { |row| truthy(row, :case_pass) }}/#{graded.size}",
                checks: "#{graded.sum { |row| value(row, :passed).to_i }}/" \
                        "#{graded.sum { |row| value(row, :total).to_i }}",
                shape_accuracy: Metrics.accuracy(graded, :shape_ok),
                decline_precision: decline[:decline_precision],
                decline_recall: decline[:decline_recall],
                checkpoint_pass_rate: Metrics.checkpoint_stats(graded)[:pass_rate]
              }
            end
          end
        end

        def checkpoint_table
          summary.map do |row|
            {
              arm: row[:arm],
              checkpoints: row[:checkpoints],
              pass_rate: row[:checkpoint_pass_rate],
              unvalidated_hops: row[:unvalidated_hops],
              first_failure_gates: row[:first_failure_gates]
            }
          end
        end

        def calibration_table
          summary.map do |row|
            list = graded_rows.select { |entry| value(entry, :arm).to_s == row[:arm] }
            pairs = Metrics.calibration_pairs(list)
            {
              arm: row[:arm],
              pairs: pairs.size,
              ece: Metrics.ece(pairs),
              brier: Metrics.brier(pairs)
            }
          end
        end

        def to_h
          {
            'meta' => redact(@meta),
            'denominator' => denominator,
            'summary' => summary,
            'families' => family_table,
            'checkpoints' => checkpoint_table,
            'calibration' => calibration_table,
            'rows' => @rows.map { |row| redact(row) }
          }
        end

        def markdown
          lines = []
          lines << "# LFM3 contracted-team benchmark — #{meta_value(:date) || 'undated'}"
          lines << ''
          lines.concat(meta_lines)
          lines << ''
          lines << '## Summary'
          lines << ''
          lines << '| arm | case-pass | checks | shape | perception | divergence | selection | ' \
                   'ECE | decline P/R | false answer | violations | checkpoint | unvalidated | ' \
                   'first failure | regressions | calls | wall | cold/warm | peak MB |'
          lines << '|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|'
          summary.each do |row|
            lines << format(
              '| %s | %s | %s | %s | %s | %s | %s | %s | %s / %s | %s | %d | %s | %d | %s | %d | %d | %s | %d/%d | %s |',
              row[:arm], row[:case_pass_label], row[:checks],
              Metrics.percent(row[:shape_accuracy]),
              Metrics.percent(row[:perception_fidelity]),
              Metrics.percent(row[:proposal_divergence]),
              Metrics.percent(row[:selection_quality]),
              Metrics.number(row[:ece]),
              Metrics.percent(row[:decline_precision]),
              Metrics.percent(row[:decline_recall]),
              Metrics.percent(row[:false_answer_rate]),
              row[:contract_violations],
              Metrics.percent(row[:checkpoint_pass_rate]),
              row[:unvalidated_hops],
              gate_text(row[:first_failure_gates]),
              row[:regressions], row[:calls],
              Metrics.number(row[:wall_s], digits: 2),
              row[:cold], row[:warm],
              Metrics.number(row[:peak_memory_mb], digits: 1)
            )
          end
          lines << ''
          lines << '## Families'
          lines << ''
          lines << '| family | arm | cases | infra | case-pass | checks | shape | decline P/R | checkpoint |'
          lines << '|---|---|---|---|---|---|---|---|---|'
          family_table.each do |row|
            lines << format(
              '| %s | %s | %d | %d | %s | %s | %s | %s / %s | %s |',
              row[:family], row[:arm], row[:cases], row[:infra], row[:case_pass],
              row[:checks], Metrics.percent(row[:shape_accuracy]),
              Metrics.percent(row[:decline_precision]),
              Metrics.percent(row[:decline_recall]),
              Metrics.percent(row[:checkpoint_pass_rate])
            )
          end
          lines << ''
          lines << '## Supervision'
          lines << ''
          lines << '| arm | checkpoints | pass rate | unvalidated hops | first-failure gates |'
          lines << '|---|---|---|---|---|'
          checkpoint_table.each do |row|
            lines << format('| %s | %d | %s | %d | %s |', row[:arm], row[:checkpoints],
                            Metrics.percent(row[:pass_rate]), row[:unvalidated_hops],
                            gate_text(row[:first_failure_gates]))
          end
          lines << ''
          lines << '## Calibration'
          lines << ''
          lines << '| arm | pairs | ECE | Brier |'
          lines << '|---|---|---|---|'
          calibration_table.each do |row|
            lines << format('| %s | %d | %s | %s |', row[:arm], row[:pairs],
                            Metrics.number(row[:ece]), Metrics.number(row[:brier]))
          end
          lines << ''
          lines << '## Denominator'
          lines << ''
          lines << "- Rows: #{denominator[:rows]}"
          lines << "- Graded: #{denominator[:graded]}"
          lines << "- Infra (excluded): #{denominator[:infra]}"
          lines << "- Cases: #{denominator[:cases]}"
          lines << "- Arms: #{denominator[:arms].join(', ')}"
          lines << ''
          lines << '## Per case'
          lines << ''
          @rows.each { |row| lines.concat(case_lines(row)) }
          lines.join("\n") + "\n"
        end

        def write!(markdown_path:, json_path:)
          [markdown_path, json_path].each do |path|
            raise Error, "refusing to overwrite existing report: #{path}" if File.exist?(path)
          end
          FileUtils.mkdir_p(File.dirname(markdown_path))
          FileUtils.mkdir_p(File.dirname(json_path))
          File.write(markdown_path, markdown)
          File.write(json_path, JSON.pretty_generate(to_h) + "\n")
          { markdown: markdown_path, json: json_path }
        end

        private

        def ordered_families
          known = Cases::FAMILIES.select do |family|
            @rows.any? { |row| value(row, :family).to_s == family }
          end
          extras = @rows.map { |row| value(row, :family).to_s }.reject(&:empty?).uniq - known
          known + extras
        end

        def group_calls(calls, key)
          calls.each_with_object(Hash.new(0)) do |call, out|
            name = value(call, key).to_s
            out[name] += 1 unless name.empty?
          end.sort.to_h
        end

        def regressions_for(arm, list)
          baseline_rows =
            if @baseline
              @baseline.is_a?(Report) ? @baseline.rows : Array(@baseline)
            else
              @rows
            end
          return 0 if baseline_rows.empty?

          list.count do |row|
            next false if truthy(row, :infra)

            baseline = baseline_match(baseline_rows, row)
            baseline && truthy(baseline, :case_pass) && !truthy(row, :case_pass)
          end
        end

        # The baseline is the same arm when it exists (an explicit prior run),
        # otherwise the matching solo arm for the family.
        def baseline_match(baseline_rows, row)
          id = value(row, :id).to_s
          seed = value(row, :seed).to_i
          candidates = baseline_rows.select do |entry|
            value(entry, :id).to_s == id && value(entry, :seed).to_i == seed &&
              !truthy(entry, :infra)
          end
          return nil if candidates.empty?

          wanted = value(row, :arm).to_s
          candidates.find { |entry| value(entry, :arm).to_s == wanted } ||
            candidates.find do |entry|
              value(entry, :arm).to_s == baseline_arm_for(value(row, :family).to_s)
            end
        end

        def baseline_arm_for(family)
          case family
          when 'vision' then 'solo-VL'
          when 'audio' then 'solo-Audio'
          when 'audio-video' then 'solo-Omni'
          when 'text', 'decision', 'out_of_scope' then 'solo-1.7B'
          end
        end

        def case_lines(row)
          lines = []
          lines << "### #{value(row, :id)} — #{value(row, :family)} — #{value(row, :arm)} — seed #{value(row, :seed)}"
          lines << ''
          lines << "- Status: `#{value(row, :status)}`#{truthy(row, :infra) ? ' (infra, excluded)' : ''}"
          lines << "- Shape: `#{value(row, :shape) || 'n/a'}` (expected `#{value(row, :expected_shape) || 'n/a'}`)"
          lines << "- Decision: `#{value(row, :decision) || 'n/a'}` (expected `#{value(row, :expected_decision)}`), " \
                   "reason `#{value(row, :reason) || 'n/a'}`" \
                   "#{value(row, :expected_reason) ? " (expected `#{value(row, :expected_reason)}`)" : ''}"
          lines << "- Checks: #{value(row, :passed)}/#{value(row, :total)}"
          lines << "- Checkpoints: #{Array(value(row, :checkpoints)).size}, " \
                   "unvalidated hops: #{value(row, :unvalidated_hops).to_i}"
          lines << "- Calls: #{calls_text(value(row, :calls))}"
          violations = Array(value(row, :violations))
          lines << "- Violations: #{violations.empty? ? '—' : violations.map { |item| value(item, :code) || value(item, :message) }.join(', ')}"
          lines << "- Ledger: `#{value(row, :ledger_dir)}`" if value(row, :ledger_dir)
          lines << ''
          lines << 'Final:'
          lines << ''
          lines << '```'
          lines << value(row, :final).to_s
          lines << '```'
          lines << ''
          checks = Array(value(row, :checks))
          unless checks.empty?
            lines << 'Checks:'
            lines << ''
            checks.each do |check|
              state = truthy(check, :pass) ? 'pass' : 'fail'
              lines << "- `#{state}` #{value(check, :kind)}: #{value(check, :name)}"
            end
            lines << ''
          end
          raw = value(row, :raw) || {}
          unless raw.empty?
            lines << '<details><summary>Raw artifacts</summary>'
            lines << ''
            raw.each do |name, text|
              next if text.nil? || text.to_s.empty?

              lines << "**#{name}:**"
              lines << ''
              lines << '```'
              lines << text.to_s
              lines << '```'
              lines << ''
            end
            lines << '</details>'
            lines << ''
          end
          lines
        end

        def calls_text(calls)
          Array(calls).map do |call|
            role = value(call, :role)
            model = value(call, :model)
            elapsed = value(call, :elapsed_s)
            [role, model, elapsed && format('%.1fs', elapsed.to_f)].compact.join(' ')
          end.join(' · ')
        end

        def gate_text(gates)
          return '—' if gates.nil? || gates.empty?

          gates.map { |gate, count| "#{gate} #{count}" }.join(', ')
        end

        def meta_lines
          lines = []
          lines << "- **Date:** #{meta_value(:date) || 'undated'}"
          lines << "- **Case file:** `#{meta_value(:cases_path) || 'n/a'}`" \
                   " (SHA-256 `#{meta_value(:cases_sha256) || 'n/a'}`)"
          lines << "- **Calibration:** `#{meta_value(:calibration_path) || 'n/a'}`" \
                   " (SHA-256 `#{meta_value(:calibration_sha256) || 'n/a'}`)"
          lines << "- **Seeds:** #{meta_value(:seeds) || '0'} · **Runs:** #{@rows.size}" \
                   " · **Infra:** #{infra_count} (excluded)"
          lines << "- **Models:** #{models_text}"
          lines << "- **Command:** `#{meta_value(:command) || 'n/a'}`"
          sampler = meta_value(:sampler)
          lines << "- **Sampler:** #{sampler_text(sampler)}"
          lines
        end

        def models_text
          models = meta_value(:models)
          return 'n/a' if models.nil? || models.empty?

          if models.is_a?(Hash)
            models.map { |role, model| "#{role}=#{model}" }.join(', ')
          else
            models.to_s
          end
        end

        def sampler_text(sampler)
          return 'n/a' unless sampler.is_a?(Hash) && !sampler.empty?

          sampler.map { |key, value| "#{key}=#{value}" }.join(', ')
        end

        def meta_value(key)
          return nil unless @meta.is_a?(Hash)

          @meta[key] || @meta[key.to_s]
        end

        def value(entry, key)
          Metrics.value(entry, key)
        end

        def truthy(entry, key)
          Metrics.truthy(entry, key)
        end

        def redact(value)
          case value
          when Hash
            value.each_with_object({}) do |(key, item), out|
              out[key.to_s] = key.to_s.match?(SECRET_KEY) ? '[REDACTED]' : redact(item)
            end
          when Array
            value.map { |item| redact(item) }
          when String
            value.gsub(SECRET_VALUE, '[REDACTED]')
          else
            value
          end
        end
      end
    end
  end
end
