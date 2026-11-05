# frozen_string_literal: true

require 'json'
require 'fileutils'

module Runes
  module Bench
    module Cumulative
      # Aggregate rows and render the Markdown + JSON decision record.
      #
      # The report deliberately keeps two denominators visible:
      #   * checks: passed / total over graded (non-infra) rows;
      #   * cases:  case-pass / graded rows.
      # An infra row is counted and named, never silently dropped.
      class Report
        class Error < StandardError; end

        SECRET_KEY = /api[_-]?key|authorization|secret|token|password/i
        SECRET_VALUE = /(?:sk-[A-Za-z0-9_-]{8,}|Bearer\s+[A-Za-z0-9._-]+)/i

        attr_reader :meta, :rows, :baseline

        def initialize(meta:, rows:, baseline: nil)
          @meta = meta || {}
          @rows = Array(rows)
          @baseline = baseline
        end

        def self.load(path)
          data = JSON.parse(File.read(path))
          rows = Array(data['rows']).map { |row| row.transform_keys(&:to_sym) }
          new(meta: data['meta'] || {}, rows: rows)
        rescue Errno::ENOENT
          raise Error, "baseline report not found: #{path}"
        rescue JSON::ParserError => e
          raise Error, "baseline report is not valid JSON: #{e.message}"
        end

        def summary
          @rows.group_by { |row| row[:arm].to_s }.map do |arm, list|
            graded = list.reject { |row| row[:infra] }
            checks_total = graded.sum { |row| row[:total].to_i }
            checks_passed = graded.sum { |row| row[:passed].to_i }
            case_pass = graded.count { |row| row[:case_pass] }
            {
              arm: arm,
              checks: "#{checks_passed}/#{checks_total}",
              checks_passed: checks_passed,
              checks_total: checks_total,
              case_pass: case_pass,
              case_denominator: graded.size,
              case_pass_label: "#{case_pass}/#{graded.size}",
              regressions: regressions_for(arm, list),
              calls: mean_range(graded.map { |row| row[:calls].size }),
              wall: mean_range(graded.map { |row| row[:elapsed_s].to_f }),
              statuses: list.group_by { |row| row[:status].to_s }.transform_values(&:size),
              infra: list.count { |row| row[:infra] }
            }
          end
        end

        def infra_count
          @rows.count { |row| row[:infra] }
        end

        def to_h
          {
            'meta' => redact(@meta),
            'summary' => summary,
            'infra' => infra_count,
            'rows' => @rows.map { |row| redact(row) }
          }
        end

        def markdown
          lines = []
          lines << "# Cumulative small-model benchmark — #{@meta[:date] || @meta['date'] || 'undated'}"
          lines << ''
          lines << "- **Model:** #{@meta[:model] || @meta['model'] || 'unknown'}"
          lines << "- **Sampler:** #{sampler_text}"
          lines << "- **Command:** `#{@meta[:command] || @meta['command'] || 'n/a'}`"
          lines << "- **Cases:** #{@meta[:cases] || @meta['cases'] || @rows.map { |r| r[:id] }.uniq.size}" \
                   " · **Seeds:** #{@meta[:seeds] || @meta['seeds'] || '0'}" \
                   " · **Runs:** #{@rows.size}"
          lines << "- **Infra:** #{infra_count} (excluded from accuracy)"
          lines << ''
          lines << '| arm | checks | case-pass | regressions | calls/task | wall/task | status |'
          lines << '|---|---|---|---|---|---|---|'
          summary.each do |row|
            lines << format(
              '| %s | %s | %s | %s | %s | %s | %s |',
              row[:arm], row[:checks], row[:case_pass_label], row[:regressions],
              row[:calls], row[:wall], status_text(row[:statuses])
            )
          end
          lines << ''
          lines << '## Per case'
          lines << ''
          @rows.each do |row|
            lines.concat(case_lines(row))
          end
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

        def case_lines(row)
          lines = []
          lines << "### #{row[:id]} — #{row[:arm]} — seed #{row[:seed]}"
          lines << ''
          lines << "**Status:** #{row[:status]}#{row[:infra] ? ' (infra, excluded)' : ''}"
          lines << ''
          lines << "**Checks:** #{row[:passed]}/#{row[:total]}"
          lines << ''
          lines << "**Calls:** #{calls_text(row[:calls])}"
          lines << ''
          violations = Array(row[:violations])
          lines << "**Violations:** #{violations.empty? ? '—' : violations.map { |v| v[:code] || v['code'] }.join(', ')}"
          lines << ''
          lines << '**Final:**'
          lines << ''
          lines << '```'
          lines << row[:final].to_s
          lines << '```'
          lines << ''
          raw = row[:raw] || {}
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

        def sampler_text
          sampler = @meta[:sampler] || @meta['sampler'] || {}
          return 'n/a' if sampler.empty?

          sampler.map { |key, value| "#{key}=#{value}" }.join(', ')
        end

        def calls_text(calls)
          Array(calls).map do |call|
            role = call[:role] || call['role']
            elapsed = call[:elapsed_s] || call['elapsed_s']
            "#{role} #{format('%.1fs', elapsed.to_f)}"
          end.join(' · ')
        end

        def status_text(statuses)
          statuses.map { |status, count| "#{status} #{count}" }.join(', ')
        end

        def regressions_for(arm, list)
          return 0 if arm == '1x'

          baseline_rows =
            if @baseline
              @baseline.rows
            else
              @rows.select { |row| row[:arm].to_s == '1x' }
            end
          return 0 if baseline_rows.empty?

          baseline_by_key = baseline_rows.each_with_object({}) do |row, out|
            out[[row[:id].to_s, row[:seed].to_i]] = row
          end
          list.count do |row|
            next false if row[:infra]

            baseline_row = baseline_by_key[[row[:id].to_s, row[:seed].to_i]]
            baseline_row && baseline_row[:case_pass] && !row[:case_pass]
          end
        end

        def mean_range(values)
          return '—' if values.empty?

          mean = values.sum.to_f / values.size
          format('%.1f (%s–%s)', mean, format_number(values.min), format_number(values.max))
        end

        def format_number(value)
          value.is_a?(Float) && value != value.to_i ? format('%.1f', value) : value.to_i.to_s
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
