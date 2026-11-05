# frozen_string_literal: true

require_relative "test_helper"
require_relative "../lib/runes"

class TeamPlanTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  AGENTS = File.join(ROOT, "config/agents")

  def registry
    @registry ||= Runes::Swarm::Registry.new(Runes::Swarm::Manifest.load_all(AGENTS))
  end

  def registry_without(*roles)
    manifests = Runes::Swarm::Manifest.load_all(AGENTS).reject { |manifest| roles.include?(manifest.role) }
    Runes::Swarm::Registry.new(manifests)
  end

  def plan(shape, **options)
    Runes::Orchestration::TeamPlan.build(shape: shape, registry: registry, **options)
  end

  def test_answer_lite_has_the_ordered_text_steps
    value = plan(:answer_lite, task: "Quel est le total ?", evidence: { "total" => "128,40" })

    assert_equal :answer_lite, value.shape
    assert_equal %i[answerer judge reviewer repairer verifier finalizer],
                 value.steps.map(&:role).uniq
    assert_equal %i[answerer judge reviewer verifier], value.steps.reject(&:optional).map(&:role)
    assert_equal "answer.v1", value.steps.find { |step| step.role == :answerer }.schema
    assert_equal "review.v1", value.steps.find { |step| step.role == :reviewer }.schema
    refute value.declined?
  end

  def test_answer_full_contracts_two_distinct_ideators
    value = plan(:answer_full, task: "Compare the two leases.", evidence: { "lease" => "a" })

    ideators = value.steps.select { |step| step.role == :ideator }
    assert_equal 2, ideators.size
    assert_equal %w[ideator.direct ideator.alternative], ideators.map(&:agent_id)
    assert_equal %w[proposal.v1 proposal.v1], ideators.map(&:schema)
    assert_equal %i[ideate_direct ideate_alternative], ideators.map(&:phase)
    refute_equal ideators[0].anchors, ideators[1].anchors
  end

  def test_perception_precedes_the_text_shape
    value = plan(:see, task: "Read the invoice.", media: [{ path: "invoice.png", modality: "image" }])

    assert_equal :vision, value.steps.first.role
    assert value.steps.first.perception?
    assert_equal "perception.v1", value.steps.first.schema
    assert_equal :answerer, value.steps[1].role
  end

  def test_hear_and_watch_pair_the_right_perception_role
    audio = plan(:hear, task: "Transcribe.", media: [{ path: "call.wav", modality: "audio" }])
    omni = plan(:watch, task: "Watch the talk.", media: [{ path: "talk.mp4", modality: "video" }])

    assert_equal :audio, audio.steps.first.role
    assert_equal :omni, omni.steps.first.role
    assert_equal "perceiver.omni", omni.steps.first.agent_id
  end

  def test_anchors_are_literal_and_occur_exactly_once
    value = plan(:answer_full, task: "task")
    text = value.to_markdown

    assert_equal %i[proposal_a proposal_b review repair], value.anchors.keys
    value.anchors.each_value do |anchor|
      assert_equal 1, text.scan(Regexp.new(Regexp.escape(anchor))).size
    end
    assert_equal value.anchors.values.uniq.size, value.anchors.size
  end

  def test_acceptance_carries_checks_questions_and_bands
    value = plan(
      :answer_full,
      task: { "question" => "total?", "checks" => { "must_cite" => ["page:1"] } },
      calibration: { "accept_support" => 0.9 }
    )

    acceptance = value.acceptance
    assert_equal({ "must_cite" => ["page:1"] }, acceptance["checks"])
    assert_equal 1, acceptance["max_repair_rounds"]
    assert_includes acceptance["questions"].map { |question| question["id"] },
                    "support_a"
    assert_in_delta 0.9, acceptance["thresholds"]["accept_support"]
    assert_in_delta 0.10, acceptance["thresholds"]["accept_contradiction"]
  end

  def test_plan_to_h_is_plan_v1_and_keeps_the_budget
    value = plan(:answer_lite, task: "task", budgets: { calls: 3, steps: 4, wall_s: 30 })
    hash = value.to_h

    assert_equal "plan.v1", hash["schema"]
    assert_equal "answer_lite", hash["shape"]
    assert_equal 3, hash["budgets"]["calls"]
    assert_equal 4, hash["budgets"]["steps"]
    assert_equal 30, hash["budgets"]["wall_s"]
    assert_equal value.steps.map(&:to_h), hash["steps"]
    parsed = Runes::Json.parse(Runes::Json.generate(hash))
    assert_equal hash, parsed
  end

  def test_a_missing_role_declines_instead_of_downgrading
    value = Runes::Orchestration::TeamPlan.build(
      shape: :answer_lite, task: "task", registry: registry_without(:answerer)
    )

    assert value.declined?
    assert_equal :no_route, value.decline_reason
    assert_includes value.decline_message, "answerer"
    assert_empty value.steps
  end

  def test_answer_full_declines_with_only_one_ideator
    manifests = Runes::Swarm::Manifest.load_all(AGENTS).reject do |manifest|
      manifest.agent_id == "ideator.alternative"
    end
    value = Runes::Orchestration::TeamPlan.build(
      shape: :answer_full, task: "task", registry: Runes::Swarm::Registry.new(manifests)
    )

    assert value.declined?
    assert_includes value.decline_message, "two contracted ideators"
  end

  def test_shape_select_routes_text_modality_and_recommended_shape
    verdict = { "shape" => "answer-lite", "modality" => "text", "scope" => 0.9, "risk" => 0.1 }

    assert_equal :answer_lite, Runes::Orchestration::Shape.select(verdict, {}, registry)
    assert_equal :decide, Runes::Orchestration::Shape.select(
      { "shape" => "decide", "modality" => "text", "scope" => 0.9 }, {}, registry
    )
  end

  def test_shape_select_routes_by_modality
    assert_equal :see, Runes::Orchestration::Shape.select(
      { "scope" => 0.9, "risk" => 0.1 }, { "modality" => "image" }, registry
    )
    assert_equal :hear, Runes::Orchestration::Shape.select(
      { "scope" => 0.9, "risk" => 0.1 }, { "modality" => "audio" }, registry
    )
    assert_equal :watch, Runes::Orchestration::Shape.select(
      { "scope" => 0.9, "risk" => 0.1 }, { "modality" => "video" }, registry
    )
  end

  def test_shape_select_escalates_unsafe_out_of_scope_and_high_risk
    assert_equal :escalate, Runes::Orchestration::Shape.select(
      { "unsafe" => true, "scope" => 0.9 }, {}, registry
    )
    assert_equal :escalate, Runes::Orchestration::Shape.select(
      { "scope" => 0.1 }, {}, registry
    )
    assert_equal :escalate, Runes::Orchestration::Shape.select(
      { "scope" => 0.9, "risk" => 0.95 }, {}, registry
    )
    assert_equal :escalate, Runes::Orchestration::Shape.select(
      { "scope" => 0.9, "decision" => "decline", "reason_code" => "out_of_scope" }, {}, registry
    )
  end

  def test_shape_select_returns_escalate_when_a_required_role_is_missing
    shape = Runes::Orchestration::Shape.select(
      { "shape" => "answer-lite", "scope" => 0.9 }, {}, registry_without(:answerer)
    )

    assert_equal :escalate, shape
  end

  def test_shape_select_routes_high_risk_to_answer_full
    shape = Runes::Orchestration::Shape.select(
      { "scope" => 0.9, "risk" => 0.7, "shape" => "answer-lite" }, {}, registry
    )

    assert_equal :answer_lite, shape

    shape = Runes::Orchestration::Shape.select(
      { "scope" => 0.9, "risk" => 0.7 }, { "multistep" => true }, registry
    )
    assert_equal :answer_full, shape
  end

  def test_shape_names_accept_hyphenated_forms
    assert_equal :answer_full, Runes::Orchestration::Shape.normalize("answer-full")
    assert_equal :answer_lite, Runes::Orchestration::Shape.normalize(:answer_lite)
    assert_nil Runes::Orchestration::Shape.normalize("unknown")
  end

  def test_task_text_is_written_verbatim
    value = plan(:answer_lite, task: { "question" => "Quel est le total ?" })

    assert_equal "Quel est le total ?", value.task_text
    assert_equal Runes::SHA256.hex("Quel est le total ?"), value.task_sha
  end
end
