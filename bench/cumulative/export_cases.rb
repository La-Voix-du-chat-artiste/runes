# frozen_string_literal: true

# One-time export tool: freeze the reference graph evidence into cases.json.
#
# This is a development tool, not a runtime dependency. The benchmark itself
# reads only the tracked cases.json.
#
#   ruby bench/cumulative/export_cases.rb \
#     --source /path/to/runes-lang/glyphes/tmp \
#     --out bench/cumulative/cases.json
#
# Use --dry-run to print the case ids and check counts without writing.

require 'digest'
require 'json'
require 'optparse'
require 'time'

module Runes
  module Bench
    module Cumulative
      module ExportCases
        module_function

        def run(argv)
          options = parse(argv)
          source = File.expand_path(options[:source])
          golden = File.join(source, 'golden_graph_queries.json')
          pilot = File.join(source, 'pilot_cumulative.rb')
          db = File.join(source, 'seshat.dev.sqlite3')
          [golden, pilot, db].each do |path|
            raise ArgumentError, "missing reference file: #{path}" unless File.file?(path)
          end

          $LOAD_PATH.unshift(source)
          require File.join(source, 'bench_graph_skill')
          require pilot

          cases = JSON.parse(File.read(golden)).fetch('cases') + Pilot.extra_cases
          api = SeshatGraph::Tools::API.new(db_path: db)
          runner = SeshatGraph::Bench::Runner.new(api: api, command: 'true')
          exported = cases.map do |spec|
            prepared = runner.prepare(spec)
            {
              'id' => spec['id'],
              'question' => spec['question'],
              'evidence' => prepared[:evidence],
              'checks' => spec['checks'],
              'tags' => spec['id'].start_with?('G') ? %w[graph golden] : %w[corpus extra]
            }
          end

          if options[:dry_run]
            exported.each do |spec|
              count = spec['checks'].values.flatten.size
              puts "#{spec['id']}: #{spec['evidence'].size} calls, #{count} checks"
            end
            puts "total: #{exported.size} cases, #{exported.sum { |s| s['checks'].values.flatten.size }} checks"
            return 0
          end

          data = {
            'provenance' => {
              'source' => options[:source_label],
              'reference_cases' => 'golden_graph_queries.json + pilot_cumulative.rb extra_cases',
              'db' => File.basename(db),
              'db_sha256' => Digest::SHA256.file(db).hexdigest,
              'exported_at' => Time.now.utc.strftime('%Y-%m-%d'),
              'note' => 'Evidence is precomputed; the benchmark does not read the reference checkout at runtime.'
            },
            'cases' => exported
          }
          File.write(options[:out], JSON.pretty_generate(data) + "\n")
          puts "wrote #{options[:out]} (#{exported.size} cases, " \
               "#{exported.sum { |s| s['checks'].values.flatten.size }} checks)"
          0
        end

        def parse(argv)
          options = {
            source: ENV['GLYPHES_TMP'].to_s,
            source_label: 'runes-lang/glyphes/tmp',
            out: File.expand_path('cases.json', __dir__),
            dry_run: false
          }
          parser = OptionParser.new do |opts|
            opts.banner = 'Usage: ruby bench/cumulative/export_cases.rb --source DIR [options]'
            opts.on('--source DIR', 'Reference glyphes/tmp checkout') { |v| options[:source] = v }
            opts.on('--source-label LABEL', 'Provenance label') { |v| options[:source_label] = v }
            opts.on('--out PATH', 'Output cases.json') { |v| options[:out] = v }
            opts.on('--dry-run', 'Print ids and counts; do not write') { options[:dry_run] = true }
            opts.on('-h', '--help', 'Show this help') { puts opts; exit 0 }
          end
          parser.parse!(argv)
          raise ArgumentError, '--source is required (or set GLYPHES_TMP)' if options[:source].empty?

          options
        end
      end
    end
  end
end

if $PROGRAM_NAME == __FILE__
  exit Runes::Bench::Cumulative::ExportCases.run(ARGV)
end
