# frozen_string_literal: true

require_relative "test_helper"
require_relative "../lib/runes"

class SwarmCheckpointTest < Minitest::Test
  def all_pass
    Runes::Swarm::Checkpoint::GATES.each_with_object({}) { |gate, out| out[gate] = :pass }
  end

  def checkpoint(gates: nil, step: 1, role: :answerer, agent_id: "answerer.grounded", violations: [])
    Runes::Swarm::Checkpoint.new(
      step: step,
      role: role,
      agent_id: agent_id,
      gates: gates || all_pass,
      violations: violations
    )
  end

  def test_all_pass_checkpoint_passes
    value = checkpoint

    assert value.passed?
    assert_empty value.failed_gates
    assert_empty value.skipped_gates
    assert_equal :pass, value.status_for(:call)
  end

  def test_a_failed_gate_fails_the_checkpoint_and_is_named
    value = checkpoint(gates: all_pass.merge(identity: :fail))

    refute value.passed?
    assert_equal %i[identity], value.failed_gates
    assert_equal :fail, value.status_for("identity")
  end

  def test_failed_gates_follow_the_fixed_gate_order
    value = checkpoint(gates: all_pass.merge(route: :fail, envelope: :fail, progress: :fail))

    assert_equal %i[envelope progress route], value.failed_gates
  end

  def test_skip_is_not_a_failure
    value = checkpoint(gates: all_pass.merge(verifier: :skip, progress: :skip))

    assert value.passed?
    assert_equal %i[verifier progress], value.skipped_gates
    assert_empty value.failed_gates
  end

  def test_it_rejects_an_unknown_gate
    error = assert_raises(Runes::Swarm::Checkpoint::Invalid) do
      checkpoint(gates: all_pass.merge(janitor: :pass))
    end
    assert_includes error.message, "unknown gate"
  end

  def test_it_rejects_a_missing_gate
    gates = all_pass.reject { |gate, _| gate == :verifier }
    error = assert_raises(Runes::Swarm::Checkpoint::Invalid) { checkpoint(gates: gates) }
    assert_includes error.message, "missing gates"
    assert_includes error.message, "verifier"
  end

  def test_it_rejects_an_unknown_status
    error = assert_raises(Runes::Swarm::Checkpoint::Invalid) do
      checkpoint(gates: all_pass.merge(call: :maybe))
    end
    assert_includes error.message, "unknown status"
  end

  def test_it_rejects_a_non_positive_step
    [0, -1, "1", nil].each do |step|
      assert_raises(Runes::Swarm::Checkpoint::Invalid, "expected step #{step.inspect} to be rejected") do
        checkpoint(step: step)
      end
    end
  end

  def test_it_rejects_an_unknown_role
    error = assert_raises(Runes::Swarm::Checkpoint::Invalid) { checkpoint(role: :janitor) }
    assert_includes error.message, "unknown role"
  end

  def test_it_rejects_an_invalid_agent_id
    assert_raises(Runes::Swarm::Checkpoint::Invalid) { checkpoint(agent_id: "Answerer") }
  end

  def test_agent_id_is_optional
    value = checkpoint(agent_id: nil)

    assert_nil value.agent_id
    assert value.passed?
  end

  def test_checkpoint_is_immutable
    value = checkpoint

    assert value.frozen?
    assert value.gates.frozen?
    assert value.violations.frozen?
    assert_raises(FrozenError) { value.gates[:call] = :fail }
  end

  def test_to_h_is_string_keyed_and_keeps_gate_order
    value = checkpoint(gates: all_pass.merge(identity: :fail))

    hash = value.to_h
    assert_equal 1, hash["step"]
    assert_equal "answerer", hash["role"]
    assert_equal "answerer.grounded", hash["agent_id"]
    assert_equal Runes::Swarm::Checkpoint::GATES.map(&:to_s), hash["gates"].keys
    assert_equal "fail", hash["gates"]["identity"]
    refute hash["passed"]
    assert_equal %w[identity], hash["failed_gates"]
  end

  def test_to_h_round_trips_through_json
    value = checkpoint(gates: all_pass.merge(verifier: :skip, budget: :fail))

    parsed = Runes::Json.parse(Runes::Json.generate(value.to_h))

    assert_equal value.to_h, parsed
  end

  def test_it_serializes_violations
    violation = Runes::Orchestration::Violation.new(
      code: "identity_mismatch",
      message: "the echoed identity differs",
      detail: ["agent_id"]
    )
    value = checkpoint(violations: [violation])

    serialized = value.to_h["violations"].first
    assert_equal "identity_mismatch", serialized["code"]
    assert_equal "the echoed identity differs", serialized["message"]
    assert_equal "error", serialized["severity"]
    assert_equal ["agent_id"], serialized["detail"]
  end
end
