# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'json'
require 'optparse'
require 'shellwords'
require 'time'

require_relative '../../lib/runes'
require_relative 'arms'
require_relative 'cases'
require_relative 'checks'
require_relative 'grade'
require_relative 'report'

module Runes
  module Bench
    module Swarm
      # CLI and orchestration for the 24-case contracted-team benchmark.
      #
      #   ruby bench/swarm/runner.rb --dry-run --case T1
      #   ruby bench/swarm/runner.rb --arm team-full --seeds 0
      #
      # The runner is deliberately boring: it loads frozen cases, creates a
      # fresh ledger per (case, arm, seed), runs one arm, re-scores the final
      # artifact independently with `Checks`, grades the decision and shape,
      # and hands the rows to `Report`. It never reads a reference checkout.
      class Runner
        class Error < StandardError; end

        DEFAULT_CASES = File.expand_path('cases.json', __dir__)
        DEFAULT_RUNS = File.expand_path('runs', __dir__)
        DEFAULT_CACHE = File.expand_path('cache', __dir__)
        DEFAULT_RESULTS = File.expand_path('results', __dir__)
        AGENTS_DIR = File.expand_path('../../config/agents', __dir__)
        GENERALIST = File.expand_path('manifests/generalist.json', __dir__)
        DEFAULT_MODEL = 'LiquidAI/LFM3-1.7B'

        DEFAULT_SAMPLER = {
          temperature: 0.1,
          top_k: 50,
          repetition_penalty: 1.1
        }.freeze

        MAX_CALLS = 8

        CONTRACT_GATE = {
          'contract_missing' => :envelope,
          'identity_missing' => :identity,
          'identity_mismatch' => :identity,
          'capacity_missing' => :capacity,
          'capacity_conflict' => :capacity,
          'capacity_overreach' => :capacity,
          'decision_missing' => :decision,
          'decision_invalid' => :decision,
          'body_missing' => :body,
          'body_forbidden' => :body,
          'output_schema_unknown' => :schema,
          'modality_mismatch' => :modality,
          'perception_shape' => :provenance,
          'provenance_missing' => :provenance,
          'forbidden_action' => :verifier,
          'calibration_low' => :calibration
        }.freeze

        attr_reader :options, :cases, :rows, :report

        def self.run(argv)
          parsed = parse(argv)
          return 0 if parsed == :help

          new(parsed).run
        rescue Error, Cases::Error, Report::Error, Arms::Error, OptionParser::ParseError => e
          warn "error: #{e.message}"
          2
        end

        def self.parse(argv)
          options = {
            arms: [],
            seeds: [0],
            case_ids: [],
            cases_path: DEFAULT_CASES,
            runs_dir: DEFAULT_RUNS,
            cache_dir: DEFAULT_CACHE,
            results_dir: DEFAULT_RESULTS,
            max_tokens: 320,
            timeout_s: 300,
            sampler: DEFAULT_SAMPLER.dup,
            dry_run: false,
            strict: false,
            reuse: false,
            cache: true
          }

          parser = OptionParser.new do |opts|
            opts.banner = 'Usage: ruby bench/swarm/runner.rb [options]'
            opts.on('--arm ARM', 'Arm; repeat or comma-separate (default: team-full)') do |value|
              options[:arms].concat(value.split(',').map(&:strip).reject(&:empty?))
            end
            opts.on('--seeds LIST', 'Comma-separated seeds (default: 0)') do |value|
              options[:seeds] = value.split(',').map { |seed| Integer(seed.strip) }
            end
            opts.on('--runs N', 'Use seeds 0..N-1') do |value|
              count = Integer(value)
              raise Error, '--runs must be positive' unless count.positive?

              options[:seeds] = (0...count).to_a
            end
            opts.on('--case ID', 'Case ID; repeat or comma-separate (default: all)') do |value|
              options[:case_ids].concat(value.split(',').map(&:strip).reject(&:empty?))
            end
            opts.on('--cases PATH', 'Case file') { |value| options[:cases_path] = value }
            opts.on('--command CMD', 'stdin→stdout text model command') { |value| options[:command] = value }
            opts.on('--base-url URL', 'OpenAI-compatible base URL') { |value| options[:base_url] = value }
            opts.on('--model NAME', 'Text model name or local path') { |value| options[:model] = value }
            opts.on('--api-key KEY', 'Optional API key for --base-url') { |value| options[:api_key] = value }
            opts.on('--python PATH', 'Python interpreter for the adapters') { |value| options[:python] = value }
            opts.on('--vl-model NAME', 'Vision model') { |value| options[:vl_model] = value }
            opts.on('--audio-model NAME', 'Audio model') { |value| options[:audio_model] = value }
            opts.on('--omni-model NAME', 'Omni model') { |value| options[:omni_model] = value }
            opts.on('--d1-model NAME', 'd1 text model') { |value| options[:d1_model] = value }
            opts.on('--d1-omni-model NAME', 'd1 Omni model') { |value| options[:d1_omni_model] = value }
            opts.on('--temperature F', Float, 'Sampler temperature') do |value|
              options[:sampler][:temperature] = value
            end
            opts.on('--top-p F', Float, 'Sampler top_p') { |value| options[:sampler][:top_p] = value }
            opts.on('--top-k N', Integer, 'Sampler top_k') { |value| options[:sampler][:top_k] = value }
            opts.on('--repetition-penalty F', Float, 'Sampler repetition penalty') do |value|
              options[:sampler][:repetition_penalty] = value
            end
            opts.on('--max-tokens N', Integer, 'Per-call output cap') { |value| options[:max_tokens] = value }
            opts.on('--timeout S', Float, 'Per-call timeout') { |value| options[:timeout_s] = value }
            opts.on('--max-wall-s S', Float, 'Per-run wall budget') { |value| options[:max_wall_s] = value }
            opts.on('--runs-dir PATH', 'Ledger root') { |value| options[:runs_dir] = value }
            opts.on('--cache-dir PATH', 'Generation cache root') { |value| options[:cache_dir] = value }
            opts.on('--results-dir PATH', 'Default report directory') { |value| options[:results_dir] = value }
            opts.on('--baseline PATH', 'Prior JSON report for regressions') { |value| options[:baseline] = value }
            opts.on('--calibration PATH', 'Calibration thresholds JSON') { |value| options[:calibration] = value }
            opts.on('--out PATH', 'Markdown report path') { |value| options[:out] = value }
            opts.on('--json PATH', 'JSON report path') { |value| options[:json] = value }
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
          options[:arms] = ['team-full'] if options[:arms].empty?
          options[:arms].each { |arm| Arms.fetch(arm) }
          raise Error, '--seeds must not be empty' if options[:seeds].empty?
          raise Error, '--seeds must be non-negative' if options[:seeds].any?(&:negative?)
          if options[:command] && options[:base_url]
            raise Error, 'choose either --command or --base-url, not both'
          end
          if options[:arms].include?('frontier-1x') &&
             (options[:base_url].to_s.empty? || options[:model].to_s.empty?)
            raise Error, 'frontier-1x needs --base-url and --model'
          end
          if options[:calibration] && !File.file?(options[:calibration].to_s)
            raise Error, "calibration file not found: #{options[:calibration]}"
          end
          if options[:baseline] && !File.file?(options[:baseline].to_s)
            raise Error, "baseline report not found: #{options[:baseline]}"
          end

          options
        end

        def initialize(options = {})
          @options = options
          @arms = Array(options.fetch(:arms, ['team-full'])).map(&:to_s)
          @seeds = Array(options.fetch(:seeds, [0])).map { |seed| Integer(seed) }
          @case_ids = Array(options.fetch(:case_ids, []))
          @cases_path = options.fetch(:cases_path, DEFAULT_CASES)
          @runs_dir = options.fetch(:runs_dir, DEFAULT_RUNS)
          @cache_dir = options.fetch(:cache_dir, DEFAULT_CACHE)
          @results_dir = options.fetch(:results_dir, DEFAULT_RESULTS)
          @max_tokens = options.fetch(:max_tokens, 320)
          @timeout_s = options.fetch(:timeout_s, 300).to_f
          @max_wall_s = options[:max_wall_s]
          @sampler = options.fetch(:sampler, DEFAULT_SAMPLER.dup)
          @dry_run = !!options[:dry_run]
          @strict = !!options[:strict]
          @reuse = !!options[:reuse]
          @cache_enabled = options.fetch(:cache, true) && !@dry_run
          @model_factory = options[:model_factory]
          @baseline_path = options[:baseline]
          @calibration_path = options[:calibration]
          @out_path = options[:out]
          @json_path = options[:json]
          @rows = []
          @report = nil
          @calibration_thresholds = load_calibration
        end

        def run
          @cases = Cases.load(@cases_path)
          selected = @cases.select(@case_ids)
          return dry_run(selected) if @dry_run

          @baseline_report = @baseline_path ? Report.load(@baseline_path) : nil
          selected.each do |spec|
            @seeds.each do |seed|
              @arms.each do |arm|
                next unless Arms.applicable?(arm, spec['family'])

                @rows << run_case(spec, arm, seed)
              end
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

        # ------------------------------------------------------------- dry run

        def dry_run(selected)
          selected.each do |spec|
            @arms.each do |arm|
              next unless Arms.applicable?(arm, spec['family'])

              dry_run_case(spec, arm)
            end
          end
          0
        end

        def dry_run_case(spec, arm)
          definition = Arms.fetch(arm)
          shape = Arms.forced_shape(arm, spec) || spec['expected_shape'] || 'auto'
          puts "=== #{arm} / #{spec['id']} — #{spec['question']} ==="
          puts "family: #{spec['family']}"
          puts "shape: #{shape}"
          puts "roles: #{Arms.roles(arm, spec).join(', ')}"
          puts "checks: #{JSON.generate(spec['checks'] || {})}"
          if spec['questions'].is_a?(Array) && !spec['questions'].empty?
            puts "typed questions: #{JSON.generate(spec['questions'])}"
          end
          puts "media: #{Array(spec['media']).join(', ')}" unless Array(spec['media']).empty?
          puts ''

          registry = registry_for(arm)
          Arms.roles(arm, spec).each do |role|
            # `team-full` also lists the case family as a pseudo-role; the
            # registry only knows contracted roles.
            next if registry && !registry.roles.include?(role.to_sym)

            manifest = registry&.by_role(role)
            next if manifest.nil?

            puts render_role(manifest, spec)
            puts ''
          end
          puts '---'
          puts ''
        end

        def render_role(manifest, spec)
          header = "[#{manifest.role}] #{manifest.agent_id} (#{manifest.base_model}, #{manifest.capacity.output_schema})"
          if Runes::Swarm::ModelFamily.deterministic?(manifest.role) ||
             manifest.base_model == Runes::Swarm::ModelFamily::RUBY
            return "#{header}\n  deterministic control role; no model call"
          end
          if %i[vision audio omni].include?(manifest.role)
            return "#{header}\n  media call: #{Array(spec['media']).join(', ')}"
          end
          if manifest.family.stamp?
            return "#{header}\n  typed call: state + questions (stamp-mode adapter)"
          end

          profile = Runes::LLM::RoleProfile.for(manifest)
          prompt = profile.prompt(
            task: spec['question'],
            evidence: spec['evidence'],
            media: Array(spec['media']).empty? ? nil : Array(spec['media'])
          )
          "#{header}\n#{prompt}"
        end

        # --------------------------------------------------------------- rows

        def run_case(spec, arm, seed)
          started = Runes::Compat.monotonic
          case Arms.fetch(arm)[:kind]
          when :conductor
            run_conductor(spec, arm, seed, started)
          when :solo, :solo_media
            run_solo(spec, arm, seed, started)
          when :frontier
            run_frontier(spec, arm, seed, started)
          when :legacy
            run_legacy(spec, arm, seed, started)
          else
            raise Error, "arm #{arm} has no runner"
          end
        rescue StandardError => e
          row_error(spec, arm, seed, started, "#{e.class}: #{e.message}")
        end

        def run_conductor(spec, arm, seed, started)
          if arm == 'adapter' && !adapter_configured?
            return infra_row(spec, arm, seed, started, 'adapter arm requested but no adapter is configured')
          end

          registry = registry_for(arm)
          models = build_models(registry, spec, arm, seed)
          ledger = ledger_for(spec, arm, seed)
          conductor = Runes::Orchestration::Conductor.new(
            registry: registry,
            ledger: ledger,
            guards: guards_for(spec),
            models: models,
            checks: spec['checks'],
            task_profile: spec['task_profile'],
            shape: Arms.forced_shape(arm, spec),
            finalize: Arms.fetch(arm)[:finalize] ? true : false,
            escalation: false,
            max_calls: Arms.fetch(arm)[:max_calls] || MAX_CALLS,
            calibration: @calibration_thresholds,
            max_wall_s: @max_wall_s
          )
          result = conductor.run(
            task: task_for(spec),
            evidence: spec['evidence'],
            media: media_entries(spec)
          )
          row_from_result(spec, arm, seed, started, result, ledger)
        end

        def run_solo(spec, arm, seed, started)
          manifest = solo_manifest(arm)
          raise Error, "arm #{arm} has no manifest" if manifest.nil?

          model = build_model(manifest, spec: spec, arm: arm, seed: seed)
          return infra_row(spec, arm, seed, started, 'no model is wired') if model.nil?

          availability = availability_error(model)
          return infra_row(spec, arm, seed, started, availability) unless availability.nil?

          ledger = ledger_for(spec, arm, seed)
          media = media_entries(spec).first
          result = if manifest.family.echo?
                     call_text_model(manifest, model, spec)
                   else
                     call_media_model(manifest, model, media)
                   end

          envelope = if result[:envelope].is_a?(Runes::Swarm::Envelope)
                       result[:envelope]
                     elsif manifest.family.echo?
                       # Stamp mode: the manifest supplies identity/capacity;
                       # the model's reply only needs DECISION + BODY.
                       Runes::Swarm::Envelope.stamp_text(result[:content], manifest: manifest)
                     end
          final = envelope ? envelope.body.to_s : result[:content].to_s
          if manifest.family.stamp? && envelope.nil? && result[:artifact].is_a?(Hash)
            final = Runes::Json.generate(result[:artifact])
          end
          decision = result[:decision] || envelope&.decision
          checks = Checks.evaluate(final, spec['checks'], gold: spec['gold'])
          grade = Grade.grade(spec: spec, decision: decision,
                              shape: Arms.forced_shape(arm, spec), final: final,
                              checks: checks)
          violations = if envelope
                         Runes::Swarm::ContractGuard.new(manifest: manifest).check_envelope(envelope)
                       else
                         []
                       end
          checkpoint = direct_checkpoint(manifest, result, envelope, checks, media)
          checkpoints = [checkpoint.to_h]
          assignment = {
            id: spec['id'],
            family: spec['family'],
            arm: arm,
            seed: seed,
            status: (result[:status] || :ok).to_s,
            shape: Arms.forced_shape(arm, spec),
            expected_shape: spec['expected_shape'],
            decision: grade[:decision],
            expected_decision: grade[:expected_decision],
            expected_reason: grade[:expected_reason],
            reason: grade[:reason],
            decision_ok: grade[:decision_ok],
            reason_ok: grade[:reason_ok],
            shape_ok: grade[:shape_ok],
            checks_ok: grade[:checks_ok],
            case_pass: grade[:case_pass],
            abstain: grade[:abstain],
            inferred: grade[:inferred],
            passed: checks.count { |check| check[:pass] },
            total: checks.size,
            checks: checks,
            checkpoints: checkpoints,
            unvalidated_hops: 0,
            calibration: calibration_from_artifact(result[:artifact], grade[:case_pass]),
            violations: violations.map(&:to_h),
            route: [],
            calls: [call_summary(manifest, result)],
            elapsed_s: (result[:elapsed_s] || (Runes::Compat.monotonic - started)).to_f,
            cold: cold?,
            warm: warm?,
            peak_memory_mb: nil,
            infra: result[:status].to_s == 'infra',
            error: result[:error],
            final: final,
            ledger_dir: ledger.dir,
            perception_ok: perception_ok([], spec),
            divergence: nil,
            selection_ok: nil,
            raw: raw_artifacts(ledger).merge('final' => final)
          }
          assignment[:case_pass] = false if assignment[:infra]
          assignment
        end

        def run_frontier(spec, arm, seed, started)
          model = frontier_model
          return infra_row(spec, arm, seed, started, 'frontier-1x needs --base-url and --model') if model.nil?

          availability = availability_error(model)
          return infra_row(spec, arm, seed, started, availability) unless availability.nil?

          ledger = ledger_for(spec, arm, seed)
          prompt = frontier_prompt(spec)
          result = model.call(prompt, role: 'escalation', max_tokens: @max_tokens)
          result = normalize_call(result)
          final = result[:content].to_s
          checks = Checks.evaluate(final, spec['checks'], gold: spec['gold'])
          grade = Grade.grade(spec: spec, decision: nil, shape: 'answer-lite',
                              final: final, checks: checks, inferred: true)
          checkpoint = control_checkpoint(:escalation, nil, result, checks)
          {
            id: spec['id'], family: spec['family'], arm: arm, seed: seed,
            status: (result[:status] || :ok).to_s,
            shape: 'escalation',
            expected_shape: spec['expected_shape'],
            decision: grade[:decision],
            expected_decision: grade[:expected_decision],
            expected_reason: grade[:expected_reason],
            reason: grade[:reason],
            decision_ok: grade[:decision_ok],
            reason_ok: grade[:reason_ok],
            shape_ok: grade[:shape_ok],
            checks_ok: grade[:checks_ok],
            case_pass: grade[:case_pass],
            abstain: grade[:abstain],
            inferred: true,
            passed: checks.count { |check| check[:pass] },
            total: checks.size,
            checks: checks,
            checkpoints: [checkpoint.to_h],
            unvalidated_hops: 0,
            calibration: [],
            violations: [],
            route: [],
            calls: [call_summary(nil, result, role: 'escalation', model: model_name(model))],
            elapsed_s: (result[:elapsed_s] || (Runes::Compat.monotonic - started)).to_f,
            cold: cold?, warm: warm?, peak_memory_mb: nil,
            infra: result[:status].to_s == 'infra',
            error: result[:error],
            final: final,
            ledger_dir: ledger.dir,
            perception_ok: nil,
            divergence: nil,
            selection_ok: nil,
            raw: raw_artifacts(ledger).merge('final' => final)
          }
        end

        def run_legacy(spec, arm, seed, started)
          manifest = Runes::Swarm::Manifest.load(GENERALIST)
          model = build_model(manifest, spec: spec, arm: arm, seed: seed)
          return infra_row(spec, arm, seed, started, 'no model is wired') if model.nil?

          availability = availability_error(model)
          return infra_row(spec, arm, seed, started, availability) unless availability.nil?

          ledger = ledger_for(spec, arm, seed)
          verifier = lambda do |artifact, **|
            Checks.evaluate(artifact, spec['checks'], gold: spec['gold'])
                  .reject { |check| check[:pass] }
                  .map do |check|
              Runes::Orchestration::Violation.new(
                code: 'benchmark_check', message: check[:name], detail: check[:error]
              )
            end
          end
          result = Runes::Orchestration::Cumulative.new(
            llm: model,
            ledger: ledger,
            guards: guards_for(spec),
            verifier: verifier,
            max_calls: Arms.fetch(arm)[:max_calls] || 3,
            mode: :adaptive,
            max_wall_s: @max_wall_s,
            model_name: model_name(model),
            sampler: @sampler,
            arm: arm,
            case_id: spec['id'],
            max_tokens: @max_tokens
          ).run(task: spec['question'], evidence: spec['evidence'])

          final = result.final.to_s
          checks = Checks.evaluate(final, spec['checks'], gold: spec['gold'])
          grade = Grade.grade(spec: spec, decision: nil,
                              shape: Arms.forced_shape(arm, spec), final: final,
                              checks: checks, inferred: true)
          checkpoint = control_checkpoint(:generalist, manifest, result, checks)
          {
            id: spec['id'], family: spec['family'], arm: arm, seed: seed,
            status: result.status.to_s,
            shape: Arms.forced_shape(arm, spec),
            expected_shape: spec['expected_shape'],
            decision: grade[:decision],
            expected_decision: grade[:expected_decision],
            expected_reason: grade[:expected_reason],
            reason: grade[:reason],
            decision_ok: grade[:decision_ok],
            reason_ok: grade[:reason_ok],
            shape_ok: grade[:shape_ok],
            checks_ok: grade[:checks_ok],
            case_pass: grade[:case_pass],
            abstain: grade[:abstain],
            inferred: true,
            passed: checks.count { |check| check[:pass] },
            total: checks.size,
            checks: checks,
            checkpoints: [checkpoint.to_h],
            unvalidated_hops: 0,
            calibration: [],
            violations: result.violations.map(&:to_h),
            route: [],
            calls: result.calls,
            elapsed_s: (result.elapsed_s || (Runes::Compat.monotonic - started)).to_f,
            cold: cold?, warm: warm?, peak_memory_mb: nil,
            infra: result.status.to_s == 'infra',
            error: result.error,
            final: final,
            ledger_dir: ledger.dir,
            perception_ok: nil,
            divergence: nil,
            selection_ok: nil,
            raw: raw_artifacts(ledger).merge('final' => final)
          }
        end

        # ------------------------------------------------------------- row glue

        def row_from_result(spec, arm, seed, started, result, ledger)
          final = result.final.to_s
          checks = Checks.evaluate(final, spec['checks'], gold: spec['gold'])
          grade = Grade.grade(spec: spec, decision: result.decision,
                              shape: result.shape, final: final, checks: checks)
          checkpoints = result.checkpoints.map(&:to_h)
          infra = result.status == :infra ||
                  result.calls.any? { |call| (call['status'] || call[:status]).to_s == 'infra' }
          calibration = calibration_from_ledger(ledger, grade[:case_pass])
          proposals = ledger.read_json(:proposals) || []
          select = Array(ledger.read_json(:calibration)).find do |entry|
            (entry['phase'] || entry[:phase]).to_s == 'select'
          end
          row = {
            id: spec['id'],
            family: spec['family'],
            arm: arm,
            seed: seed,
            status: result.status.to_s,
            shape: result.shape&.to_s,
            expected_shape: spec['expected_shape'],
            decision: grade[:decision],
            expected_decision: grade[:expected_decision],
            expected_reason: grade[:expected_reason],
            reason: grade[:reason],
            decision_ok: grade[:decision_ok],
            reason_ok: grade[:reason_ok],
            shape_ok: grade[:shape_ok],
            checks_ok: grade[:checks_ok],
            case_pass: grade[:case_pass] && !infra,
            abstain: grade[:abstain],
            inferred: grade[:inferred],
            passed: checks.count { |check| check[:pass] },
            total: checks.size,
            checks: checks,
            checkpoints: checkpoints,
            unvalidated_hops: result.unvalidated_hops,
            calibration: calibration,
            violations: result.violations.map(&:to_h),
            route: result.route,
            calls: result.calls,
            elapsed_s: (result.elapsed_s || (Runes::Compat.monotonic - started)).to_f,
            cold: cold?,
            warm: warm?,
            peak_memory_mb: nil,
            infra: infra,
            error: result.error,
            final: final,
            ledger_dir: ledger.dir,
            perception_ok: perception_ok(ledger, spec),
            divergence: proposals.size >= 2 &&
                        proposals.map { |proposal| proposal['sha256'] || proposal[:sha256] }.uniq.size > 1,
            selection_ok: select.nil? ? nil : grade[:case_pass],
            raw: raw_artifacts(ledger)
          }
          row[:case_pass] = false if infra
          row
        end

        def row_error(spec, arm, seed, started, message)
          {
            id: spec['id'], family: spec['family'], arm: arm, seed: seed,
            status: 'error', shape: Arms.forced_shape(arm, spec),
            expected_shape: spec['expected_shape'],
            decision: nil, expected_decision: (spec['expected_decision'] || 'accept'),
            expected_reason: spec['expected_reason'], reason: nil,
            decision_ok: false, reason_ok: spec['expected_reason'].nil?,
            shape_ok: nil, checks_ok: false, case_pass: false,
            abstain: false, inferred: false,
            passed: 0, total: @cases ? @cases.check_count(spec['checks']) : 0,
            checks: [], checkpoints: [], unvalidated_hops: 0,
            calibration: [], violations: [], route: [], calls: [],
            elapsed_s: (Runes::Compat.monotonic - started).to_f,
            cold: cold?, warm: warm?, peak_memory_mb: nil,
            infra: false, error: message, final: '', ledger_dir: nil,
            perception_ok: nil, divergence: nil, selection_ok: nil, raw: {}
          }
        end

        def infra_row(spec, arm, seed, started, message)
          {
            id: spec['id'], family: spec['family'], arm: arm, seed: seed,
            status: 'infra', shape: Arms.forced_shape(arm, spec),
            expected_shape: spec['expected_shape'],
            decision: nil, expected_decision: (spec['expected_decision'] || 'accept'),
            expected_reason: spec['expected_reason'], reason: nil,
            decision_ok: false, reason_ok: spec['expected_reason'].nil?,
            shape_ok: nil, checks_ok: false, case_pass: false,
            abstain: false, inferred: false,
            passed: 0, total: @cases ? @cases.check_count(spec['checks']) : 0,
            checks: [], checkpoints: [], unvalidated_hops: 0,
            calibration: [], violations: [], route: [], calls: [],
            elapsed_s: (Runes::Compat.monotonic - started).to_f,
            cold: cold?, warm: warm?, peak_memory_mb: nil,
            infra: true, error: message, final: '', ledger_dir: nil,
            perception_ok: nil, divergence: nil, selection_ok: nil, raw: {}
          }
        end

        # ------------------------------------------------------------- models

        def registry_for(arm)
          return Runes::Swarm::Registry.new([]) if arm == 'frontier-1x'
          return Runes::Swarm::Registry.new([solo_manifest(arm)]) if %w[solo-1.7B same-model-3x].include?(arm)

          Runes::Swarm::Registry.new(Runes::Swarm::Manifest.load_all(AGENTS_DIR))
        end

        def solo_manifest(arm)
          case arm
          when 'solo-1.7B', 'same-model-3x' then Runes::Swarm::Manifest.load(GENERALIST)
          when 'solo-VL' then production_manifest('perceiver.vision')
          when 'solo-Audio' then production_manifest('perceiver.audio')
          when 'solo-Omni' then production_manifest('perceiver.omni')
          end
        end

        def production_manifest(agent_id)
          Runes::Swarm::Manifest.load_all(AGENTS_DIR).find { |manifest| manifest.agent_id == agent_id }
        end

        def build_models(registry, spec, arm, seed)
          registry.each_with_object({}) do |manifest, out|
            next if Runes::Swarm::ModelFamily.deterministic?(manifest.role)

            model = build_model(manifest, spec: spec, arm: arm, seed: seed)
            out[manifest.agent_id] = model unless model.nil?
          end
        end

        def build_model(manifest, spec:, arm:, seed:)
          return nil if manifest.nil?
          return nil if Runes::Swarm::ModelFamily.deterministic?(manifest.role)

          if @model_factory
            return @model_factory.call(manifest, spec: spec, arm: arm, seed: seed)
          end

          case manifest.base_model.to_s
          when 'external'
            frontier_model
          when 'LiquidAI/d1-2B'
            Runes::LLM::D1Adapter.new(
              **adapter_options.merge(model: @options[:d1_model] || manifest.base_model)
            )
          when 'LiquidAI/d1-Omni-2B'
            Runes::LLM::D1Adapter.new(
              **adapter_options.merge(model: @options[:d1_omni_model] || manifest.base_model)
            )
          when 'LiquidAI/LFM3-VL-2B'
            media_adapter(:vision, @options[:vl_model] || manifest.base_model)
          when 'LiquidAI/LFM3-Audio-2B'
            media_adapter(:audio, @options[:audio_model] || manifest.base_model)
          when 'LiquidAI/LFM3-Omni-2B'
            media_adapter(:omni, @options[:omni_model] || manifest.base_model)
          when 'LiquidAI/LFM3-1.7B', 'LiquidAI/LFM3-1.7B-Base'
            text_adapter(@options[:model] || manifest.base_model)
          end
        end

        def text_adapter(model)
          adapter = Runes::LLM::Lfm3Adapter.new(
            **adapter_options.merge(model: model, max_tokens: @max_tokens, sampler: @sampler)
          )
          wrap_text_cache(adapter)
        end

        def media_adapter(family, model)
          Runes::LLM::MediaAdapter.new(
            family: family,
            **adapter_options.merge(model: model, max_tokens: @max_tokens)
          )
        end

        def frontier_model
          return nil if @options[:base_url].to_s.empty? || @options[:model].to_s.empty?

          Runes::LLM::OpenAICompatModel.new(
            base_url: @options[:base_url].to_s,
            model: @options[:model].to_s,
            api_key: @options[:api_key],
            timeout_s: @timeout_s,
            sampler: @sampler
          )
        end

        def adapter_options
          mode = @options[:base_url] ? :server : :command
          out = {
            mode: mode,
            base_url: @options[:base_url],
            api_key: @options[:api_key],
            timeout_s: @timeout_s
          }
          if mode == :command
            out[:python] = @options[:python] if @options[:python]
            out[:command] = Shellwords.split(@options[:command].to_s) if @options[:command]
          end
          out
        end

        def wrap_text_cache(adapter)
          return adapter unless @cache_enabled

          CachedTextModel.new(
            inner: adapter,
            cache: Cache.new(@cache_dir),
            sampler: @sampler,
            max_tokens: @max_tokens,
            reuse: @reuse
          )
        end

        def availability_error(model)
          return nil unless model.respond_to?(:available?)
          return nil if model.available?

          message = if model.respond_to?(:availability_error)
                      model.availability_error
                    end
          message.to_s.empty? ? 'model is unavailable' : message
        end

        # ------------------------------------------------------------- calls

        def call_text_model(manifest, model, spec)
          profile = Runes::LLM::RoleProfile.for(manifest)
          prompt = profile.prompt(
            task: spec['question'],
            evidence: spec['evidence'],
            media: media_entries(spec).empty? ? nil : Array(spec['media'])
          )
          normalize_call(
            model.call(prompt, role: manifest.role.to_s,
                       max_tokens: manifest.capacity.max_output_tokens)
          )
        end

        def call_media_model(manifest, model, media)
          raise Error, "arm needs media for #{manifest.role}" if media.nil?

          normalize_call(
            model.call(media['path'], role: manifest.role.to_s, manifest: manifest)
          )
        end

        def normalize_call(result)
          return result if result.is_a?(Hash)

          { ok: true, content: result.to_s, status: :ok }
        end

        def call_summary(manifest, result, role: nil, model: nil)
          {
            'role' => (role || manifest&.role).to_s,
            'model' => (model || manifest&.base_model).to_s,
            'status' => (result[:status] || :ok).to_s,
            'elapsed_s' => result[:elapsed_s],
            'error' => result[:error],
            'finish_reason' => result[:finish_reason],
            'prompt_chars' => result[:prompt_chars],
            'completion_chars' => result[:content].to_s.length
          }
        end

        # ------------------------------------------------------------- support

        def guards_for(spec)
          Runes::Orchestration::Guards.new(
            task: spec['question'],
            evidence: spec['evidence'],
            checks: spec['checks']
          )
        end

        def task_for(spec)
          hash = { 'question' => spec['question'] }
          profile = spec['task_profile'] || {}
          profile.each { |key, value| hash[key.to_s] = value }
          hash['questions'] = spec['questions'] if spec['questions'].is_a?(Array)
          hash['checks'] = spec['checks'] if spec['checks'].is_a?(Hash)
          hash
        end

        def media_entries(spec)
          Array(spec['media']).map do |relative|
            path = @cases.media_path(relative)
            {
              'path' => path,
              'modality' => @cases.media_modality(relative),
              'sha256' => Digest::SHA256.file(path).hexdigest
            }
          end
        end

        def ledger_for(spec, arm, seed)
          # WorkLedger run_ids are lowercase [a-z0-9._-]; downcase the arm so
          # e.g. solo-1.7B becomes solo-1-7b.
          run_id = "#{spec['id'].downcase}-#{arm.downcase.gsub(/[^a-z0-9]+/i, '-')}-s#{seed}"
          Runes::WorkLedger.new(root: @runs_dir, run_id: run_id)
        end

        def direct_checkpoint(manifest, result, envelope, checks, media)
          gates = blank_gates
          violations = []
          call_ok = result[:ok] != false && result[:status].to_s != 'infra'
          gates[:call] = call_ok ? :pass : :fail
          if envelope
            gates[:envelope] = :pass
            contract = Runes::Swarm::ContractGuard.new(manifest: manifest).check_envelope(envelope)
            apply_contract_gates!(gates, contract)
            violations.concat(contract)
            gates[:schema] = envelope.capacity&.output_schema == manifest.capacity.output_schema ? :pass : :fail
            gates[:body] = envelope_body_ok?(envelope) ? :pass : :fail
          else
            %i[envelope identity capacity decision body schema].each { |gate| gates[gate] = :skip }
          end
          gates[:modality] = :pass
          gates[:provenance] = media ? :pass : :skip
          gates[:verifier] = Checks.passed?(checks) ? :pass : :fail
          gates[:calibration] = :skip
          gates[:progress] = :pass
          gates[:budget] = :pass
          gates[:route] = :pass
          Runes::Swarm::Checkpoint.new(
            step: 1, role: manifest.role, agent_id: manifest.agent_id,
            gates: gates, violations: violations
          )
        end

        def control_checkpoint(role, manifest, result, checks)
          gates = blank_gates
          status = result.respond_to?(:status) ? result.status : result[:status]
          gates[:call] = status.to_s == 'infra' ? :fail : :pass
          gates[:verifier] = Checks.passed?(checks) ? :pass : :fail
          gates[:progress] = :pass
          gates[:budget] = :pass
          gates[:route] = :pass
          Runes::Swarm::Checkpoint.new(
            step: 1, role: role,
            agent_id: manifest&.agent_id,
            gates: gates, violations: []
          )
        end

        def blank_gates
          Runes::Swarm::Checkpoint::GATES.each_with_object({}) { |gate, out| out[gate] = :skip }
        end

        def apply_contract_gates!(gates, violations)
          %i[identity capacity decision body schema modality provenance].each do |gate|
            gates[gate] = :pass
          end
          violations.each do |item|
            code = item.respond_to?(:code) ? item.code : item[:code]
            gate = CONTRACT_GATE[code.to_s]
            gates[gate] = :fail unless gate.nil?
          end
        end

        def envelope_body_ok?(envelope)
          decision = envelope.decision
          return false if decision.nil?
          return !decision.body.strip.empty? if decision.accept?

          decision.body.strip.empty?
        end

        def perception_ok(ledger, spec)
          return nil unless spec['perception_checks'].is_a?(Hash)

          entries = ledger.respond_to?(:read_json) ? Array(ledger.read_json(:perception)) : []
          text = entries.map { |entry| Runes::Json.generate(entry['artifact'] || entry[:artifact]) }.join("\n")
          return false if text.strip.empty?

          Checks.passed?(Checks.evaluate(text, spec['perception_checks'], gold: spec['gold']))
        end

        def calibration_from_ledger(ledger, correct)
          records = Array(ledger.read_json(:calibration))
          records.flat_map do |record|
            phase = (record['phase'] || record[:phase]).to_s
            artifact = record['artifact'] || record[:artifact]
            pairs = []
            Array(artifact.is_a?(Hash) ? (artifact['answers'] || artifact[:answers]) : []).each do |answer|
              confidence = %w[probability prob p confidence score].filter_map do |key|
                answer[key] || answer[key.to_sym]
              end.first
              next if confidence.nil?

              pairs << { phase: phase, confidence: confidence.to_f, correct: correct }
            end
            %w[support_a support_b].each do |key|
              value = record[key] || record[key.to_sym]
              pairs << { phase: phase, confidence: value.to_f, correct: correct } unless value.nil?
            end
            pairs
          end
        end

        def calibration_from_artifact(artifact, correct)
          return [] unless artifact.is_a?(Hash)

          Array(artifact['answers'] || artifact[:answers]).filter_map do |answer|
            confidence = %w[probability prob p confidence score].filter_map do |key|
              answer[key] || answer[key.to_sym]
            end.first
            next if confidence.nil?

            { phase: 'solo', confidence: confidence.to_f, correct: correct }
          end
        end

        def raw_artifacts(ledger)
          %i[task triage plan perception proposals review test_output final_test_output
             calibration decline draft critique final].each_with_object({}) do |name, out|
            text = ledger.read(name)
            out[name.to_s] = text unless text.nil? || text.empty?
          end
        end

        def adapter_configured?
          return true if @options[:adapter]

          Runes::Swarm::Manifest.load_all(AGENTS_DIR).any? do |manifest|
            manifest.family.echo? && !manifest.adapter_sha256.to_s.empty?
          end
        end

        def cold?
          @options[:base_url].nil?
        end

        def warm?
          !@options[:base_url].nil?
        end

        def model_name(model)
          return model.model_name if model.respond_to?(:model_name)

          model.class.name
        end

        def frontier_prompt(spec)
          <<~PROMPT
            Answer the task using only the supplied evidence.
            If the task is outside your capacity, decline explicitly.
            End with a Citations: line naming the anchors you used.

            TASK:
            #{spec['question']}

            EVIDENCE:
            #{JSON.generate(spec['evidence'])}
          PROMPT
        end

        # ------------------------------------------------------------- report

        def load_calibration
          return nil if @calibration_path.nil?

          data = JSON.parse(File.read(@calibration_path))
          raise Error, 'calibration file must contain an object' unless data.is_a?(Hash)

          data
        rescue JSON::ParserError => e
          raise Error, "calibration file is not valid JSON: #{e.message}"
        end

        def meta(selected)
          {
            date: Time.now.utc.strftime('%Y-%m-%d'),
            cases: selected.size,
            cases_path: @cases_path.to_s,
            cases_sha256: @cases.file_sha256,
            calibration_path: @calibration_path,
            calibration_sha256: calibration_sha,
            seeds: @seeds.join(','),
            arms: @arms,
            models: model_meta,
            sampler: @sampler,
            command: command_description,
            provenance: @cases.provenance
          }
        end

        def model_meta
          {
            'text' => @options[:model] || DEFAULT_MODEL,
            'd1' => @options[:d1_model] || 'LiquidAI/d1-2B',
            'd1-omni' => @options[:d1_omni_model] || 'LiquidAI/d1-Omni-2B',
            'vision' => @options[:vl_model] || 'LiquidAI/LFM3-VL-2B',
            'audio' => @options[:audio_model] || 'LiquidAI/LFM3-Audio-2B',
            'omni' => @options[:omni_model] || 'LiquidAI/LFM3-Omni-2B'
          }
        end

        def command_description
          return @options[:command] if @options[:command]
          return "server #{@options[:base_url]}" if @options[:base_url]
          return 'injected model factory' if @model_factory

          'adapter defaults (command mode)'
        end

        def calibration_sha
          return nil if @calibration_path.nil?

          Digest::SHA256.file(@calibration_path).hexdigest
        end

        def write_report(report)
          out, json = report_paths
          written = report.write!(markdown_path: out, json_path: json)
          puts written[:markdown]
          puts written[:json]
        end

        def report_paths
          stamp = Time.now.utc.strftime('%Y-%m-%d-%H%M%S')
          label = @arms.size == 1 ? @arms.first : 'all-arms'
          out = @out_path || File.join(@results_dir, "#{stamp}-#{label}.md")
          json = @json_path || out.sub(/\.md\z/, '') + '.json'
          [out, json]
        end

        # --------------------------------------------------------------- cache

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

        class CachedTextModel
          def initialize(inner:, cache:, sampler:, max_tokens:, reuse: false)
            @inner = inner
            @cache = cache
            @sampler = sampler
            @max_tokens = max_tokens
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
                ok: false, content: nil, usage: nil, finish_reason: nil,
                status: :infra, error: "cache miss for #{key}"
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
  exit Runes::Bench::Swarm::Runner.run(ARGV)
end
