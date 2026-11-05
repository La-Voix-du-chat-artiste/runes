# frozen_string_literal: true

require_relative "test_helper"
require_relative "../lib/runes"

class SwarmContractGuardTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  AGENTS = File.join(ROOT, "config/agents")

  def setup
    manifests = Runes::Swarm::Manifest.load_all(AGENTS)
    @answerer = manifests.find { |manifest| manifest.role == :answerer }
    @critic = manifests.find { |manifest| manifest.role == :critic }
  end

  def guard(manifest: @answerer, required: [])
    Runes::Swarm::ContractGuard.new(manifest: manifest, required: required)
  end

  def envelope_for(manifest: @answerer, status: "accept", reason: "ok", hop: "null",
                   body: "The room has two windows.", can: nil, cannot: nil,
                   schema: nil)
    can ||= manifest.capacity.can
    cannot ||= manifest.capacity.cannot
    schema ||= manifest.capacity.output_schema
    <<~TEXT
      ### IDENTITY
      agent_id: #{manifest.agent_id}
      version: #{manifest.version}
      role: #{manifest.role}
      base_model: #{manifest.base_model}
      adapter: #{manifest.adapter}
      adapter_sha256: #{manifest.adapter_sha256 || 'null'}

      ### CAPACITIES
      can: #{Array(can).join(', ')}
      cannot: #{Array(cannot).join(', ')}
      max_input_tokens: #{manifest.capacity.max_input_tokens}
      max_output_tokens: #{manifest.capacity.max_output_tokens}
      output_schema: #{schema}

      ### DECISION
      status: #{status}
      reason_code: #{reason}
      next: #{hop}
      message: done

      ### BODY
      #{body}
    TEXT
  end

  def codes(violations)
    violations.map(&:code)
  end

  def test_a_clean_answerer_envelope_has_no_violations
    assert_empty guard.check(envelope_for)
  end

  def test_no_envelope_is_contract_missing
    violations = guard.check("The room has two windows.")

    assert_equal ["contract_missing"], codes(violations)
    assert violations.first.error?
  end

  def test_a_missing_identity_block_is_identity_missing
    text = envelope_for.sub(/### IDENTITY\n.*?\n\n(?=### CAPACITIES)/m, "")

    assert_equal ["identity_missing"], codes(guard.check(text))
  end

  def test_an_empty_identity_heading_is_identity_missing_not_contract_missing
    violations = guard.check("### IDENTITY\n")

    assert_includes codes(violations), "identity_missing"
    refute_includes codes(violations), "contract_missing"
  end

  def test_a_missing_capacity_block_is_capacity_missing
    text = envelope_for.sub(/### CAPACITIES\n.*?\n\n(?=### DECISION)/m, "")

    assert_equal ["capacity_missing"], codes(guard.check(text))
  end

  def test_a_missing_decision_block_is_decision_missing
    text = envelope_for.sub(/### DECISION\n.*?\n\n(?=### BODY)/m, "")

    assert_equal ["decision_missing"], codes(guard.check(text))
  end

  def test_an_agent_id_mismatch_is_identity_mismatch
    text = envelope_for.sub("agent_id: answerer.grounded", "agent_id: critic.claims")

    assert_includes codes(guard.check(text)), "identity_mismatch"
  end

  def test_an_adapter_hash_mismatch_is_identity_mismatch
    text = envelope_for.sub("adapter_sha256: null", "adapter_sha256: #{'a' * 64}")

    assert_includes codes(guard.check(text)), "identity_mismatch"
  end

  def test_a_capability_outside_the_manifest_is_overreach
    text = envelope_for(can: @answerer.capacity.can + [:teleport])

    assert_includes codes(guard.check(text)), "capacity_overreach"
  end

  def test_claiming_write_code_is_overreach
    text = envelope_for(can: @answerer.capacity.can + [:write_code])

    assert_includes codes(guard.check(text)), "capacity_overreach"
  end

  def test_omitting_a_required_capability_is_capacity_missing
    text = envelope_for(can: %i[read_evidence answer_fr])
    violations = guard(required: %i[read_evidence answer_fr cite]).check(text)

    assert_includes codes(violations), "capacity_missing"
    assert_includes violations.find { |violation| violation.code == "capacity_missing" }.message, "cite"
  end

  def test_a_capability_in_both_can_and_cannot_is_capacity_conflict
    text = envelope_for(
      can: %i[read_evidence answer_fr cite],
      cannot: %i[retrieve cite]
    )

    assert_includes codes(guard.check(text)), "capacity_conflict"
  end

  def test_an_unknown_status_is_decision_invalid
    text = envelope_for(status: "maybe")

    assert_includes codes(guard.check(text)), "decision_invalid"
  end

  def test_an_unknown_reason_is_decision_invalid
    text = envelope_for(status: "decline", reason: "because", hop: "human", body: "")

    assert_includes codes(guard.check(text)), "decision_invalid"
  end

  def test_an_unknown_hop_is_decision_invalid
    text = envelope_for(status: "decline", reason: "missing_evidence", hop: "generalist", body: "")

    assert_includes codes(guard.check(text)), "decision_invalid"
  end

  def test_accept_with_an_empty_body_is_body_missing
    text = envelope_for(body: "")

    assert_includes codes(guard.check(text)), "body_missing"
  end

  def test_decline_with_a_body_is_body_forbidden
    text = envelope_for(
      status: "decline",
      reason: "missing_evidence",
      hop: "human",
      body: "I cannot answer."
    )

    assert_includes codes(guard.check(text)), "body_forbidden"
  end

  def test_escalate_with_a_body_is_body_forbidden
    text = envelope_for(
      status: "escalate",
      reason: "needs_human",
      hop: "human",
      body: "Here is an answer."
    )

    assert_includes codes(guard.check(text)), "body_forbidden"
  end

  def test_escalate_without_a_hop_is_decision_invalid
    text = envelope_for(status: "escalate", reason: "needs_human", hop: "null", body: "")

    assert_includes codes(guard.check(text)), "decision_invalid"
  end

  def test_a_raw_tool_call_is_forbidden_for_an_answerer
    text = envelope_for(body: '{"tool":"resolve_room","args":{"room":"A"}}')

    assert_includes codes(guard.check(text)), "forbidden_action"
  end

  def test_a_critic_citation_line_without_critique_sections_is_forbidden
    text = envelope_for(manifest: @critic, body: "Citations: book/chapter/code")

    assert_includes codes(guard(manifest: @critic).check(text)), "forbidden_action"
  end

  def test_a_critic_with_a_critique_section_is_allowed
    text = envelope_for(manifest: @critic, body: "### CLAIMS\n- one supported claim")

    refute_includes codes(guard(manifest: @critic).check(text)), "forbidden_action"
  end

  def test_an_unknown_output_schema_is_rejected
    text = envelope_for(schema: "answer.v2")

    assert_includes codes(guard.check(text)), "output_schema_unknown"
  end

  def test_an_omitted_output_schema_is_rejected
    text = envelope_for.sub("output_schema: answer.v1\n", "")

    assert_includes codes(guard.check(text)), "output_schema_unknown"
  end

  def test_a_known_but_wrong_output_schema_is_rejected
    text = envelope_for(manifest: @critic, schema: "answer.v1")

    assert_includes codes(guard(manifest: @critic).check(text)), "output_schema_unknown"
  end

  def test_check_envelope_accepts_an_already_parsed_envelope
    envelope = Runes::Swarm::Envelope.parse(envelope_for)
    violations = guard.check_envelope(envelope)

    assert_empty violations
  end

  def test_every_violation_is_an_error
    violations = guard.check("not an envelope")

    assert violations.all?(&:error?)
  end

  def test_a_stamped_envelope_carries_the_assigned_identity
    decision = Runes::Swarm::Decision.new(
      status: :accept,
      reason_code: :ok,
      body: '{"total":"128,40"}'
    )
    envelope = Runes::Swarm::Envelope.stamp(
      manifest: @answerer,
      decision: decision,
      body: decision.body
    )

    assert envelope.complete?
    assert_equal @answerer.agent_id, envelope.identity.agent_id
    assert_equal @answerer.capacity.output_schema, envelope.capacity.output_schema
    assert_empty guard.check_envelope(envelope)
  end

  def test_a_text_role_is_rejected_for_an_image
    violations = guard.check_artifact({}, modality: :image)

    assert_equal ["modality_mismatch"], codes(violations)
  end

  def test_a_perception_artifact_requires_anchors
    vision = Runes::Swarm::Manifest.load_all(AGENTS).find { |m| m.role == :vision }
    violations = guard(manifest: vision).check_artifact(
      { "modality" => "image", "source_sha256" => "a" * 64, "anchors" => [] },
      modality: :image
    )

    assert_equal ["provenance_missing"], codes(violations)
  end

  def test_a_perception_artifact_requires_the_required_fields
    vision = Runes::Swarm::Manifest.load_all(AGENTS).find { |m| m.role == :vision }
    violations = guard(manifest: vision).check_artifact(
      { "modality" => "image" },
      modality: :image
    )

    assert_equal ["perception_shape"], codes(violations)
    assert_includes violations.first.message, "source_sha256"
  end

  def test_a_clean_perception_artifact_passes
    vision = Runes::Swarm::Manifest.load_all(AGENTS).find { |m| m.role == :vision }
    violations = guard(manifest: vision).check_artifact(
      {
        "modality" => "image",
        "source_sha256" => "a" * 64,
        "anchors" => ["page:1", "box:10,20,30,40"]
      },
      modality: :image
    )

    assert_empty violations
  end

  def test_low_support_is_a_calibration_violation
    violations = guard.check_artifact(
      { "calibration" => { "support" => 0.2 } }
    )

    assert_equal ["calibration_low"], codes(violations)
  end

  def test_high_contradiction_is_a_calibration_violation
    violations = guard.check_artifact(
      { "calibration" => { "contradiction" => 0.6 } }
    )

    assert_equal ["calibration_low"], codes(violations)
  end

  def test_a_supported_artifact_passes_the_calibration_gate
    violations = guard.check_artifact(
      { "calibration" => { "support" => 0.9, "contradiction" => 0.05 } }
    )

    assert_empty violations
  end
end
