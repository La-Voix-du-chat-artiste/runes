# frozen_string_literal: true

require_relative 'test_helper'
require_relative '../lib/runes'
require_relative '../bench/swarm/arms'
require_relative '../bench/swarm/cases'
require_relative '../bench/swarm/checks'
require_relative '../bench/swarm/grade'
require_relative '../bench/swarm/metrics'
require_relative '../bench/swarm/report'
require_relative '../bench/swarm/runner'
require_relative 'support/swarm_bench_fakes'

# Phase 6 acceptance for the 24-case contracted-team benchmark.
#
# The fake models below are scripted: this test never loads an LFM3 checkpoint,
# touches the network or needs a GPU. It exercises the runner's control plane,
# the independent checks, the report and the pure metrics.
class BenchSwarmTest < Minitest::Test
  SWARM = File.expand_path('../bench/swarm', __dir__)
  CASES = File.join(SWARM, 'cases.json')

  def setup
    @root = Dir.mktmpdir('runes-bench-swarm-')
  end

  def teardown
    FileUtils.remove_entry(@root, true) if @root && Dir.exist?(@root)
  end

  # ------------------------------------------------------------ case loading

  def test_case_file_loads_and_has_24_cases_across_six_families
    cases = Runes::Bench::Swarm::Cases.load(CASES)

    assert_equal 24, cases.cases.size
    assert_equal %w[text vision audio audio-video decision out_of_scope], cases.families
    assert_equal 41, cases.total_checks
    assert_match(/\A[0-9a-f]{64}\z/, cases.file_sha256)
  end

  def test_case_loading_rejects_duplicate_ids
    error = assert_raises(Runes::Bench::Swarm::Cases::Error) do
      load_cases([base_case, base_case])
    end
    assert_includes error.message, 'duplicate case id'
  end

  def test_case_loading_rejects_unknown_families
    error = assert_raises(Runes::Bench::Swarm::Cases::Error) do
      load_cases([base_case('family' => 'video')])
    end
    assert_includes error.message, 'unknown family'
  end

  def test_case_loading_rejects_missing_media
    error = assert_raises(Runes::Bench::Swarm::Cases::Error) do
      load_cases([base_case('family' => 'vision', 'media' => ['fixtures/nope.png'])])
    end
    assert_includes error.message, 'media file not found'
  end

  def test_case_loading_rejects_a_decline_without_a_reason
    error = assert_raises(Runes::Bench::Swarm::Cases::Error) do
      load_cases([base_case('expected_decision' => 'decline')])
    end
    assert_includes error.message, 'must name expected_reason'
  end

  def test_case_loading_rejects_an_unknown_check_key
    error = assert_raises(Runes::Bench::Swarm::Cases::Error) do
      load_cases([base_case('checks' => { 'must_match' => ['x'], 'surprise' => ['y'] })])
    end
    assert_includes error.message, 'unknown keys'
  end

  # -------------------------------------------------------------- arm tables

  def test_team_full_declares_every_role
    roles = Runes::Bench::Swarm::Arms.roles('team-full', base_case)

    %w[conductor planner triage judge vision audio omni ideator answerer critic
       repairer finalizer reviewer verifier escalation].each do |role|
      assert_includes roles, role
    end
  end

  def test_arms_are_applicable_only_on_their_families
    arms = Runes::Bench::Swarm::Arms

    assert arms.applicable?('solo-VL', 'vision')
    refute arms.applicable?('solo-VL', 'text')
    assert arms.applicable?('solo-Audio', 'audio')
    assert arms.applicable?('solo-Omni', 'audio-video')
    assert arms.applicable?('d1-only', 'decision')
    refute arms.applicable?('d1-only', 'vision')
    assert arms.applicable?('team-full', 'out_of_scope')
  end

  def test_perception_arm_follows_the_fixture_family
    arms = Runes::Bench::Swarm::Arms

    assert_equal 'see', arms.forced_shape('perception+text-lite', 'family' => 'vision')
    assert_equal 'hear', arms.forced_shape('perception+text-lite', 'family' => 'audio')
    assert_equal 'watch', arms.forced_shape('perception+text-lite', 'family' => 'audio-video')
    assert_nil arms.forced_shape('team-full', 'family' => 'vision')
  end

  def test_same_model_control_is_never_a_candidate
    definition = Runes::Bench::Swarm::Arms.fetch('same-model-3x')

    assert_equal :legacy, definition[:kind]
    assert_equal 3, definition[:max_calls]
    refute Runes::Bench::Swarm::Arms.conductor?('same-model-3x')
  end

  # ------------------------------------------------------------------ grading

  def test_grading_accepts_the_expected_decision_and_shape
    spec = base_case('expected_decision' => 'accept', 'expected_shape' => 'answer-lite')
    graded = Runes::Bench::Swarm::Grade.grade(
      spec: spec,
      decision: { 'status' => 'accept', 'reason_code' => 'ok' },
      shape: 'answer-lite',
      final: 'the answer',
      checks: [{ pass: true }]
    )

    assert graded[:decision_ok]
    assert graded[:reason_ok]
    assert graded[:shape_ok]
    assert graded[:case_pass]
    refute graded[:inferred]
  end

  def test_grading_rejects_a_mismatched_decision_or_shape
    spec = base_case('expected_decision' => 'decline',
                     'expected_reason' => 'conflicting_evidence',
                     'expected_shape' => 'decide')
    graded = Runes::Bench::Swarm::Grade.grade(
      spec: spec,
      decision: { 'status' => 'accept', 'reason_code' => 'ok' },
      shape: 'answer-full',
      final: 'the answer',
      checks: [{ pass: true }]
    )

    refute graded[:decision_ok]
    refute graded[:reason_ok]
    refute graded[:shape_ok]
    refute graded[:case_pass]
  end

  def test_legacy_decisions_are_inferred_and_labelled
    spec = base_case('expected_decision' => 'decline')
    graded = Runes::Bench::Swarm::Grade.grade(
      spec: spec, decision: nil, shape: 'answer-lite', final: '', checks: [], inferred: true
    )

    assert_equal 'decline', graded[:decision]
    assert graded[:inferred]
  end

  # ------------------------------------------------------------------ metrics

  def test_decline_precision_recall_and_false_answers
    rows = [
      { expected_decision: 'decline', decision: 'decline', final: '' },
      { expected_decision: 'decline', decision: 'accept', final: 'made up' },
      { expected_decision: 'accept', decision: 'decline', final: '' },
      { expected_decision: 'decline', decision: 'accept', final: 'infra', infra: true }
    ]
    metrics = Runes::Bench::Swarm::Metrics.decline_metrics(rows)

    assert_equal 2, metrics[:expected_declines]
    assert_equal 2, metrics[:predicted_declines]
    assert_equal 1, metrics[:true_declines]
    assert_in_delta 0.5, metrics[:decline_precision]
    assert_in_delta 0.5, metrics[:decline_recall]
    assert_equal 1, metrics[:false_answers]
    assert_in_delta 0.5, metrics[:false_answer_rate]
    assert_equal 1, metrics[:over_declines]
    assert_in_delta 1.0, metrics[:over_decline_rate]
  end

  def test_checkpoint_pass_rate_unvalidated_hops_and_first_failure_gate
    rows = [
      {
        unvalidated_hops: 0,
        checkpoints: [
          { passed: true, gates: { 'call' => 'pass', 'schema' => 'pass' } }
        ]
      },
      {
        unvalidated_hops: 1,
        checkpoints: [
          { passed: false, gates: { 'call' => 'pass', 'schema' => 'fail' } }
        ]
      },
      { unvalidated_hops: 0, checkpoints: [], infra: true }
    ]
    stats = Runes::Bench::Swarm::Metrics.checkpoint_stats(rows)

    assert_equal 2, stats[:total]
    assert_equal 1, stats[:passed]
    assert_in_delta 0.5, stats[:pass_rate]
    assert_equal 1, stats[:unvalidated_hops]
    assert_equal({ 'schema' => 1 }, stats[:first_failure_gates])
  end

  def test_calibration_ece_and_brier
    metrics = Runes::Bench::Swarm::Metrics

    assert_in_delta 0.0, metrics.ece([[1.0, true], [0.0, false]])
    assert_in_delta 0.0, metrics.brier([[1.0, true], [0.0, false]])
    # Both 0.8 pairs share one bucket: ECE = |acc 0.5 - conf 0.8| = 0.3.
    assert_in_delta 0.3, metrics.ece([[0.8, true], [0.8, false]])
    assert_in_delta 0.34, metrics.brier([[0.8, true], [0.8, false]])
    assert_nil metrics.ece([])
  end

  def test_infra_rows_are_excluded_from_the_denominator
    report = Runes::Bench::Swarm::Report.new(
      meta: { date: '2026-11-03' },
      rows: [
        { id: 'T1', arm: 'team-full', family: 'text', seed: 0, case_pass: true,
          passed: 1, total: 1, infra: false, decision: 'accept', final: 'ok',
          expected_decision: 'accept', checkpoints: [] },
        { id: 'T2', arm: 'team-full', family: 'text', seed: 0, case_pass: false,
          passed: 0, total: 1, infra: true, decision: nil, final: '',
          expected_decision: 'accept', checkpoints: [] }
      ]
    )

    assert_equal 2, report.denominator[:rows]
    assert_equal 1, report.denominator[:graded]
    assert_equal 1, report.denominator[:infra]
    assert_equal 1, report.summary.first[:graded]
  end

  def test_report_refuses_to_overwrite_an_existing_path
    report = Runes::Bench::Swarm::Report.new(meta: {}, rows: [])
    path = File.join(@root, 'report.md')
    File.write(path, 'already here')
    json = File.join(@root, 'report.json')

    error = assert_raises(Runes::Bench::Swarm::Report::Error) do
      report.write!(markdown_path: path, json_path: json)
    end
    assert_includes error.message, 'refusing to overwrite'
  end

  # ------------------------------------------------------------------ runner

  def test_dry_run_calls_no_model
    factory = lambda do |*_args, **_kwargs|
      raise 'the dry run called a model'
    end
    runner = Runes::Bench::Swarm::Runner.new(
      arms: ['team-full'],
      case_ids: ['T1'],
      cases_path: CASES,
      runs_dir: File.join(@root, 'runs'),
      results_dir: File.join(@root, 'results'),
      dry_run: true,
      model_factory: factory
    )

    _out, _err = capture_io { assert_equal 0, runner.run }
    assert_empty runner.rows
  end

  def test_fake_team_full_run_over_all_24_cases
    runner = Runes::Bench::Swarm::Runner.new(
      arms: ['team-full'],
      cases_path: CASES,
      runs_dir: File.join(@root, 'runs'),
      results_dir: File.join(@root, 'results'),
      out: File.join(@root, 'report.md'),
      json: File.join(@root, 'report.json'),
      cache: false,
      model_factory: Runes::Bench::Swarm::Fakes.factory
    )

    status = nil
    _out, _err = capture_io { status = runner.run }

    assert_equal 0, status
    assert_equal 24, runner.rows.size
    runner.rows.each do |row|
      refute row[:infra], "#{row[:id]} unexpectedly became infra: #{row[:error]}"
      refute_nil row[:shape], "#{row[:id]} has no shape"
      refute_empty row[:decision].to_s, "#{row[:id]} has no decision"
      refute_empty row[:checkpoints], "#{row[:id]} has no checkpoint"
    end
    assert runner.rows.count { |row| row[:case_pass] } >= 20

    assert File.file?(File.join(@root, 'report.md'))
    assert File.file?(File.join(@root, 'report.json'))
    data = JSON.parse(File.read(File.join(@root, 'report.json')))
    assert_equal 24, data['denominator']['rows']
    assert_equal 6, data['families'].map { |row| row['family'] }.uniq.size
    assert data['summary'].first['checkpoint_pass_rate'].positive?

    text = File.read(File.join(@root, 'report.md'))
    assert_includes text, '## Families'
    assert_includes text, 'audio-video'
    assert_includes text, '## Supervision'
    assert_includes text, '## Calibration'
  end

  def test_benchmark_never_references_the_reference_checkout
    %w[runner.rb report.rb cases.rb arms.rb checks.rb metrics.rb grade.rb].each do |name|
      text = File.read(File.join(SWARM, name))
      refute_includes text, 'runes-lang/glyphes/tmp'
    end
  end

  private

  def base_case(overrides = {})
    {
      'id' => 'T1',
      'family' => 'text',
      'question' => 'Quel est le total ?',
      'evidence' => [{ 'citation' => 'doc:t1#p1', 'text' => 'Le total est 128,40 €.' }],
      'media' => [],
      'gold' => { 'answer' => '128,40 €' },
      'checks' => { 'must_cite' => ['doc:t1#p1'], 'must_match' => ['128[,.]40'] },
      'expected_shape' => 'answer-lite',
      'expected_decision' => 'accept',
      'task_profile' => { 'intent' => 'answer', 'modality' => 'text' }
    }.merge(overrides)
  end

  def load_cases(specs)
    path = File.join(@root, "cases-#{specs.size}-#{rand(1_000_000)}.json")
    File.write(path, JSON.generate('cases' => specs))
    Runes::Bench::Swarm::Cases.load(path)
  end
end
