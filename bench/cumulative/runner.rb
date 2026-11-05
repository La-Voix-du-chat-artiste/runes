# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'json'
require 'optparse'
require 'shellwords'
require 'time'

require_relative '../../lib/runes'
require_relative 'cases'
require_relative 'checks'
require_relative 'prompts'
require_relative 'report'

module Runes
  module Bench
    module Cumulative
      # CLI and orchestration for the 12-case cumulative benchmark.
      #
      #   ruby bench/cumulative/runner.rb --arm 2x-adaptive --dry-run
      #   ruby bench/cumulative/runner.rb --arm 2x-adaptive \
      #     --command "bench/cumulative/bonsai_cli.py --model $BONSAI_MODEL"
      #
      # The runner is deliberately boring: it loads data, creates a fresh
      # ledger per (case, seed, arm), runs the library, re-scores the final
      # artifact independently, and hands the rows to Report.
      class Runner
        class Error < StandardError; end

        ARMS = {
          '1x' => { max_calls: 1, mode: :adaptive },
          '2x-adaptive' => { max_calls: 2, mode: :adaptive },
          '2x-forced' => { max_calls: 2, mode: :forced },
          '3x-adaptive' => { max_calls: 3, mode: :adaptive },
          '3x-forced' => { max_calls: 3, mode: :forced },
          'frontier-1x' => { max_calls: 1, mode: :adaptive }
        }.freeze

        DEFAULT_CASES = File.expand_path('cases.json', __dir__)
        DEFAULT_RUNS = File.expand_path('runs', __dir__)
        DEFAULT_CACHE = File.expand_path('cache', __dir__)
        DEFAULT_RESULTS = File.expand_path('results', __dir__)

        attr_reader :options, :cases, :rows, :report

        def self.run(argv)
          parsed = parse(argv)
          return 0 if parsed == :help

          new(parsed).run
        rescue Error, Cases::Error, Report::Error, OptionParser::ParseError => e
          warn "error: #{e.message}"
          2
        end

        def self.parse(argv)
          options = {
            arm: '2x-adaptive',
            seeds: [0],
            case_ids: [],
            cases_path: DEFAULT_CASES,
            runs_dir: DEFAULT_RUNS,
            cache_dir: DEFAULT_CACHE,
            results_dir: DEFAULT_RESULTS,
            max_tokens: Runes::LLM::BonsaiAdapter::DEFAULT_MAX_TOKENS,
            timeout_s: 300,
            sampler: Runes::LLM::BonsaiAdapter::DEFAULT_SAMPLER.dup,
            dry_run: false,
            strict: false,
            reuse: false,
            cache: true
          }

          parser = OptionParser.new do |opts|
            opts.banner = 'Usage: ruby bench/cumulative/runner.rb [options]'
            opts.on('--arm ARM', "Arm: #{ARMS.keys.join('|')}") { |v| options[:arm] = v }
            opts.on('--seeds LIST', 'Comma-separated seeds (default: 0)') do |v|
              options[:seeds] = v.split(',').map { |seed| Integer(seed.strip) }
            end
            opts.on('--runs N', 'Use seeds 0..N-1') do |v|
              count = Integer(v)
              raise Error, '--runs must be positive' unless count.positive?

              options[:seeds] = (0...count).to_a
            end
            opts.on('--case ID', 'Case ID; repeat or comma-separate (default: all)') do |v|
              options[:case_ids].concat(v.split(',').map(&:strip).reject(&:empty?))
            end
            opts.on('--cases PATH', 'Case file') { |v| options[:cases_path] = v }
            opts.on('--command CMD', 'stdin→stdout model command') { |v| options[:command] = v }
            opts.on('--base-url URL', 'OpenAI-compatible base URL') { |v| options[:base_url] = v }
            opts.on('--model NAME', 'Model name or local path') { |v| options[:model] = v }
            opts.on('--api-key KEY', 'Optional API key for --base-url') { |v| options[:api_key] = v }
            opts.on('--temperature F', Float, 'Sampler temperature') { |v| options[:sampler][:temperature] = v }
            opts.on('--top-p F', Float, 'Sampler top_p') { |v| options[:sampler][:top_p] = v }
            opts.on('--top-k N', Integer, 'Sampler top_k') { |v| options[:sampler][:top_k] = v }
            opts.on('--presence-penalty F', Float, 'Sampler presence penalty') do |v|
              options[:sampler][:presence_penalty] = v
            end
            opts.on('--max-tokens N', Integer, 'Per-call output cap') { |v| options[:max_tokens] = v }
            opts.on('--timeout S', Float, 'Per-call timeout') { |v| options[:timeout_s] = v }
            opts.on('--max-wall-s S', Float, 'Per-run wall budget') { |v| options[:max_wall_s] = v }
            opts.on('--runs-dir PATH', 'Ledger root') { |v| options[:runs_dir] = v }
            opts.on('--cache-dir PATH', 'Generation cache root') { |v| options[:cache_dir] = v }
            opts.on('--results-dir PATH', 'Default report directory') { |v| options[:results_dir] = v }
            opts.on('--baseline PATH', 'Prior JSON report for regressions') { |v| options[:baseline] = v }
            opts.on('--out PATH', 'Markdown report path') { |v| options[:out] = v }
            opts.on('--json PATH', 'JSON report path') { |v| options[:json] = v }
            opts.on('--reuse', 'Read cached generations; never call the model') { options[:reuse] = true }
            opts.on('--no-cache', 'Disable generation cache reads and writes') { options[:cache] = false }
            opts.on('--dry-run', 'Print prompts and checks; call no model') { options[:dry_run] = true }
            opts.on('--strict', 'Exit 1 on any non-infra case failure') { options[:strict] = true }
            opts.on('-h', '--help', 'Show this help') do
              puts opts
              return :help
            end
          end
          parser.parse!(argv)
          validate_options(options)
          options
        end

        def self.validate_options(options)
          unless ARMS.key?(options[:arm])
            raise Error, "unknown arm #{options[:arm].inspect}; choose #{ARMS.keys.join(', ')}"
          end
          raise Error, '--seeds must not be empty' if options[:seeds].empty?
          raise Error, '--seeds must be non-negative' if options[:seeds].any?(&:negative?)
          if options[:arm] == 'frontier-1x' && (options[:base_url].to_s.empty? || options[:model].to_s.empty?)
            raise Error, 'frontier-1x needs --base-url and --model'
          end

          options
        end

        def initialize(options = {})
          @options = options
          @arm = options.fetch(:arm, '2x-adaptive').to_s
          @seeds = Array(options.fetch(:seeds, [0])).map { |seed| Integer(seed) }
          @case_ids = Array(options.fetch(:case_ids, []))
          @cases_path = options.fetch(:cases_path, DEFAULT_CASES)
          @runs_dir = options.fetch(:runs_dir, DEFAULT_RUNS)
          @cache_dir = options.fetch(:cache_dir, DEFAULT_CACHE)
          @results_dir = options.fetch(:results_dir, DEFAULT_RESULTS)
          @max_tokens = options.fetch(:max_tokens, Runes::LLM::BonsaiAdapter::DEFAULT_MAX_TOKENS)
          @timeout_s = options.fetch(:timeout_s, 300).to_f
          @max_wall_s = options[:max_wall_s]
          @sampler = options.fetch(:sampler, Runes::LLM::BonsaiAdapter::DEFAULT_SAMPLER.dup)
          @dry_run = !!options[:dry_run]
          @strict = !!options[:strict]
          @reuse = !!options[:reuse]
          @cache_enabled = options.fetch(:cache, true) && !@dry_run
          @model_factory = options[:model_factory]
          @baseline_path = options[:baseline]
          @out_path = options[:out]
          @json_path = options[:json]
          @rows = []
          @report = nil
        end

        def run
          @cases = Cases.load(@cases_path)
          selected = @cases.select(@case_ids)
          return dry_run(selected) if @dry_run

          @baseline_report = @baseline_path ? Report.load(@baseline_path) : nil
          selected.each do |spec|
            @seeds.each do |seed|
              @rows << run_case(spec, seed)
            end
          end

          @report = Report.new(meta: meta(selected), rows: @rows, baseline: @baseline_report)
          write_report(@report)
          @strict && failure? ? 1 : 0
        end

        def failure?
          @rows.any? { |row| !row[:infra] && !row[:case_pass] }
        end

        private

        def dry_run(selected)
          selected.each do |spec|
            puts "=== #{spec['id']} — #{spec['question']} ==="
            puts Prompts.solver_prompt(spec['question'], spec['evidence'])
            puts "CHECKS: #{JSON.generate(spec['checks'])}"
            puts
          end
          0
        end

        def run_case(spec, seed)
          run_id = "#{spec['id'].downcase}-#{@arm}-s#{seed}"
          ledger = Runes::WorkLedger.new(root: @runs_dir, run_id: run_id)
          guards = Runes::Orchestration::Guards.new(task: spec['question'], evidence: spec['evidence'])
          model = build_model(spec, seed)
          arm = ARMS.fetch(@arm)
          result = Runes::Orchestration::Cumulative.new(
            llm: model,
            ledger: ledger,
            guards: guards,
            verifier: verifier(spec['checks']),
            max_calls: arm[:max_calls],
            mode: arm[:mode],
            max_wall_s: @max_wall_s,
            prompts: Prompts.instructions,
            model_name: model_name(model),
            sampler: @sampler,
            arm: @arm,
            case_id: spec['id'],
            max_tokens: @max_tokens
          ).run(task: spec['question'], evidence: spec['evidence'])

          checks = Checks.evaluate(result.final.to_s, spec['checks'])
          passed = checks.count { |check| check[:pass] }
          total = checks.size
          calls = result.receipt ? result.receipt.calls : []
          {
            id: spec['id'],
            arm: @arm,
            seed: seed,
            status: result.status.to_s,
            case_pass: Checks.passed?(checks),
            passed: passed,
            total: total,
            checks: checks,
            calls: calls,
            violations: result.violations.map(&:to_h),
            elapsed_s: (result.elapsed_s || 0).to_f,
            infra: result.status.to_s == 'infra',
            error: result.error,
            final: result.final.to_s,
            ledger_dir: ledger.dir,
            raw: {
              draft: ledger.read(:draft),
              critique: ledger.read(:critique),
              final: ledger.read(:final)
            }
          }
        end

        def verifier(checks)
          lambda do |artifact, **|
            Checks.evaluate(artifact, checks).reject { |check| check[:pass] }.map do |check|
              Runes::Orchestration::Violation.new(
                code: 'benchmark_check',
                message: check[:name],
                detail: check[:error]
              )
            end
          end
        end

        def build_model(spec, seed)
          return @model_factory.call(spec, seed) if @model_factory

          if @arm == 'frontier-1x'
            return Runes::LLM::OpenAICompatModel.new(
              base_url: @options[:base_url].to_s,
              model: @options[:model].to_s,
              api_key: @options[:api_key],
              timeout_s: @timeout_s,
              sampler: @sampler
            )
          end

          model =
            if @options[:base_url]
              Runes::LLM::BonsaiAdapter.new(
                mode: :server,
                base_url: @options[:base_url],
                model: @options[:model].to_s,
                timeout_s: @timeout_s,
                max_tokens: @max_tokens,
                sampler: @sampler
              )
            elsif @options[:command]
              Runes::LLM::BonsaiAdapter.new(
                mode: :command,
                command: Shellwords.split(@options[:command].to_s),
                model: @options[:model].to_s,
                timeout_s: @timeout_s,
                max_tokens: @max_tokens,
                sampler: @sampler
              )
            else
              Runes::LLM::BonsaiAdapter.from_env
            end
          wrap_cache(model)
        end

        def wrap_cache(model)
          return model unless @cache_enabled

          CachedModel.new(
            inner: model,
            cache: Cache.new(@cache_dir),
            sampler: @sampler,
            reuse: @reuse
          )
        end

        def model_name(model)
          return model.model_name if model.respond_to?(:model_name)

          model.class.name
        end

        def meta(selected)
          {
            date: Time.now.utc.strftime('%Y-%m-%d'),
            model: @options[:model] || 'bonsai-2b',
            sampler: @sampler,
            command: command_description,
            cases: selected.size,
            seeds: @seeds.join(','),
            arm: @arm,
            provenance: @cases.provenance
          }
        end

        def command_description
          return @options[:command] if @options[:command]
          return "server #{@options[:base_url]}" if @options[:base_url]
          return 'BONSAI_MODE=command (from environment)' if @options[:model_factory].nil?

          'injected model factory'
        end

        def write_report(report)
          out, json = report_paths
          written = report.write!(markdown_path: out, json_path: json)
          puts written[:markdown]
          puts written[:json]
        end

        def report_paths
          stamp = Time.now.utc.strftime('%Y-%m-%d-%H%M%S')
          out = @out_path || File.join(@results_dir, "#{stamp}-#{@arm}.md")
          json = @json_path || out.sub(/\.md\z/, '') + '.json'
          [out, json]
        end

        # Cache a successful generation keyed by the exact prompt, model,
        # sampler and max_tokens. A timeout or a missing binary is never a
        # cache hit.
        class Cache
          def initialize(root)
            @root = root.to_s
            FileUtils.mkdir_p(@root)
          end

          def read(key)
            path = path_for(key)
            return nil unless File.file?(path)

            JSON.parse(File.read(path)).transform_keys(&:to_sym)
          rescue JSON::ParserError
            nil
          end

          def write(key, result)
            return nil unless result.is_a?(Hash) && result[:ok]
            return nil if result[:content].to_s.empty?

            path = path_for(key)
            FileUtils.mkdir_p(File.dirname(path))
            File.write(path, JSON.generate(result))
            path
          end

          private

          def path_for(key)
            File.join(@root, "#{key}.json")
          end
        end

        class CachedModel
          attr_reader :inner

          def initialize(inner:, cache:, sampler:, reuse: false)
            @inner = inner
            @cache = cache
            @sampler = sampler
            @reuse = reuse
          end

          def model_name
            @inner.respond_to?(:model_name) ? @inner.model_name : @inner.class.name
          end

          def available?
            @inner.respond_to?(:available?) ? @inner.available? : true
          end

          def availability_error
            @inner.respond_to?(:availability_error) ? @inner.availability_error : nil
          end

          def call(prompt, role: nil, max_tokens: nil)
            key = cache_key(prompt, role, max_tokens)
            cached = @cache.read(key)
            return cached if cached

            if @reuse
              return {
                ok: false,
                content: nil,
                usage: nil,
                finish_reason: nil,
                status: :infra,
                error: "cache miss for #{key}"
              }
            end

            result = @inner.call(prompt, role: role, max_tokens: max_tokens)
            @cache.write(key, result)
            result
          end

          private

          def cache_key(prompt, role, max_tokens)
            payload = {
              model: model_name,
              sampler: @sampler,
              role: role.to_s,
              max_tokens: max_tokens,
              prompt: prompt.to_s
            }
            Digest::SHA256.hexdigest(JSON.generate(payload))
          end
        end
      end
    end
  end
end

if $PROGRAM_NAME == __FILE__
  exit Runes::Bench::Cumulative::Runner.run(ARGV)
end
