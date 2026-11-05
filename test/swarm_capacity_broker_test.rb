# frozen_string_literal: true

require_relative "test_helper"
require_relative "../lib/runes"

class SwarmCapacityBrokerTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  AGENTS = File.join(ROOT, "config/agents")

  def setup
    manifests = Runes::Swarm::Manifest.load_all(AGENTS)
    @answerer = manifests.find { |manifest| manifest.role == :answerer }
    @scout = manifests.find { |manifest| manifest.role == :scout }
    @evidence = [{ "text" => "The room has two windows." }]
  end

  def broker(max_calls: 3, max_wall_s: nil)
    Runes::Swarm::CapacityBroker.new(max_calls: max_calls, max_wall_s: max_wall_s)
  end

  def authorize(manifest: @answerer, task: {}, evidence: @evidence, calls_used: 0, elapsed_s: 0.0, **options)
    broker(**options).authorize(
      manifest: manifest,
      task: task,
      evidence: evidence,
      calls_used: calls_used,
      elapsed_s: elapsed_s
    )
  end

  def test_nil_manifest_is_no_route
    decision = authorize(manifest: nil)

    assert decision.decline?
    assert_equal :no_route, decision.reason_code
    assert decision.body_empty?
  end

  def test_call_budget_is_exhausted
    decision = authorize(calls_used: 2, max_calls: 2)

    assert decision.decline?
    assert_equal :budget_exhausted, decision.reason_code
  end

  def test_wall_budget_is_exhausted
    decision = authorize(elapsed_s: 5.0, max_wall_s: 5)

    assert decision.decline?
    assert_equal :budget_exhausted, decision.reason_code
  end

  def test_a_nil_wall_budget_disables_the_wall_check
    decision = authorize(elapsed_s: 1_000_000.0, max_wall_s: nil)

    assert decision.accept?
  end

  def test_manifest_that_requires_evidence_declines_without_it
    [nil, "", [], {}].each do |evidence|
      decision = authorize(evidence: evidence)

      assert decision.decline?, "expected #{evidence.inspect} to be treated as empty"
      assert_equal :missing_evidence, decision.reason_code
    end
  end

  def test_task_profile_can_require_evidence
    decision = authorize(
      manifest: @scout,
      task: { evidence: :required },
      evidence: nil
    )

    assert decision.decline?
    assert_equal :missing_evidence, decision.reason_code
  end

  def test_missing_required_capabilities_decline
    decision = authorize(task: { required: %i[read_evidence write_code] })

    assert decision.decline?
    assert_equal :out_of_capacity, decision.reason_code
    assert_includes decision.message, "write_code"
  end

  def test_accepts_a_task_inside_the_manifest
    decision = authorize(task: { required: %i[read_evidence answer_fr cite] })

    assert decision.accept?
    assert_equal :ok, decision.reason_code
    refute decision.body_empty?
  end

  def test_string_keys_are_accepted_in_the_task_profile
    decision = authorize(task: { "required" => %w[read_evidence answer_fr], "evidence" => "required" })

    assert decision.accept?
  end

  def test_rule_order_prefers_no_route_over_budget
    decision = authorize(manifest: nil, calls_used: 99, max_calls: 1)

    assert_equal :no_route, decision.reason_code
  end

  def test_rule_order_prefers_budget_over_evidence
    decision = authorize(evidence: nil, calls_used: 1, max_calls: 1)

    assert_equal :budget_exhausted, decision.reason_code
  end

  def test_rule_order_prefers_wall_budget_over_evidence
    decision = authorize(evidence: nil, elapsed_s: 10.0, max_wall_s: 10)

    assert_equal :budget_exhausted, decision.reason_code
  end

  def test_rule_order_prefers_evidence_over_capacity
    decision = authorize(task: { required: %i[write_code] }, evidence: nil)

    assert_equal :missing_evidence, decision.reason_code
  end

  def test_it_rejects_invalid_budgets
    assert_raises(ArgumentError) { Runes::Swarm::CapacityBroker.new(max_calls: 0) }
    assert_raises(ArgumentError) { Runes::Swarm::CapacityBroker.new(max_calls: "3") }
    assert_raises(ArgumentError) { Runes::Swarm::CapacityBroker.new(max_wall_s: 0) }
  end

  def test_a_text_role_cannot_consume_an_image
    decision = authorize(task: { modality: :image })

    assert decision.decline?
    assert_equal :out_of_modality, decision.reason_code
    assert_includes decision.message, "image"
  end

  def test_a_vision_role_can_consume_an_image
    vision = Runes::Swarm::Manifest.load_all(AGENTS).find { |m| m.role == :vision }
    decision = authorize(manifest: vision, task: { modality: :image }, evidence: nil)

    assert decision.accept?
  end

  def test_rule_order_prefers_modality_over_evidence
    decision = authorize(task: { modality: :image }, evidence: nil)

    assert_equal :out_of_modality, decision.reason_code
  end

  def test_rule_order_prefers_evidence_over_calibration
    decision = authorize(
      task: { calibration: { support: 0.1 } },
      evidence: nil
    )

    assert_equal :missing_evidence, decision.reason_code
  end

  def test_low_support_is_declined
    decision = authorize(task: { calibration: { support: 0.2 } })

    assert decision.decline?
    assert_equal :low_support, decision.reason_code
  end

  def test_high_contradiction_is_declined
    decision = authorize(task: { calibration: { contradiction: 0.6 } })

    assert decision.decline?
    assert_equal :low_support, decision.reason_code
  end

  def test_a_supported_answer_is_accepted
    decision = authorize(task: { calibration: { support: 0.9, contradiction: 0.05 } })

    assert decision.accept?
  end

  def test_string_keys_are_accepted_in_the_calibration_profile
    decision = authorize(task: { "calibration" => { "support" => 0.1 } })

    assert decision.decline?
    assert_equal :low_support, decision.reason_code
  end
end
