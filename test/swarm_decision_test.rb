# frozen_string_literal: true

require_relative "test_helper"
require_relative "../lib/runes"

class SwarmDecisionTest < Minitest::Test
  def accept(overrides = {})
    defaults = { status: :accept, reason_code: :ok, body: "The room has two windows." }
    Runes::Swarm::Decision.new(**defaults.merge(overrides))
  end

  def decline(overrides = {})
    defaults = {
      status: :decline,
      reason_code: :missing_evidence,
      next_hop: :human,
      message: "No evidence packet was supplied."
    }
    Runes::Swarm::Decision.new(**defaults.merge(overrides))
  end

  def escalate(overrides = {})
    defaults = {
      status: :escalate,
      reason_code: :needs_human,
      next_hop: :human,
      message: "This needs a human decision."
    }
    Runes::Swarm::Decision.new(**defaults.merge(overrides))
  end

  def test_accept_predicates_and_body
    decision = accept

    assert decision.accept?
    refute decision.decline?
    refute decision.escalate?
    assert decision.body_required?
    refute decision.body_empty?
    assert_equal "The room has two windows.", decision.body
  end

  def test_decline_predicates_and_body
    decision = decline

    refute decision.accept?
    assert decision.decline?
    refute decision.escalate?
    refute decision.body_required?
    assert decision.body_empty?
    assert_equal "", decision.body
  end

  def test_escalate_predicates
    decision = escalate

    assert decision.escalate?
    refute decision.accept?
    refute decision.decline?
    assert_equal :human, decision.next_hop
  end

  def test_to_h_is_string_keyed_and_round_trips
    decision = accept(body: "Answer.")

    assert_equal(
      {
        "status" => "accept",
        "reason_code" => "ok",
        "next_hop" => nil,
        "message" => nil,
        "body" => "Answer."
      },
      decision.to_h
    )
    assert_equal decision, Runes::Swarm::Decision.from_h(decision.to_h)
    assert_equal decision, Runes::Swarm::Decision.from_h(decision.to_h.transform_keys(&:to_sym))
  end

  def test_decision_is_immutable
    decision = accept

    assert decision.frozen?
    assert decision.body.frozen?
    assert_raises(FrozenError) { decision.body << " Changed." }
  end

  def test_value_equality
    assert_equal decline, decline
    refute_equal decline, decline(reason_code: :low_confidence)
  end

  def test_accept_requires_a_non_empty_body
    ["", "   ", nil].each do |body|
      error = assert_raises(Runes::Swarm::Decision::Invalid, "expected body #{body.inspect} to be rejected") do
        accept(body: body)
      end
      assert_includes error.message, "non-empty body"
    end
  end

  def test_accept_requires_ok_reason
    error = assert_raises(Runes::Swarm::Decision::Invalid) do
      accept(reason_code: :low_confidence)
    end
    assert_includes error.message, "reason_code :ok"
  end

  def test_accept_must_not_carry_a_next_hop
    error = assert_raises(Runes::Swarm::Decision::Invalid) do
      accept(next_hop: :finalizer)
    end
    assert_includes error.message, "next_hop"
  end

  def test_decline_must_not_carry_a_body
    error = assert_raises(Runes::Swarm::Decision::Invalid) do
      decline(body: "I cannot answer.")
    end
    assert_includes error.message, "must not carry a body"
  end

  def test_decline_requires_a_non_ok_reason
    error = assert_raises(Runes::Swarm::Decision::Invalid) do
      decline(reason_code: :ok)
    end
    assert_includes error.message, "non-:ok reason_code"
  end

  def test_escalate_requires_a_next_hop
    error = assert_raises(Runes::Swarm::Decision::Invalid) do
      escalate(next_hop: nil)
    end
    assert_includes error.message, "requires a next_hop"
  end

  def test_escalate_must_not_carry_a_body
    assert_raises(Runes::Swarm::Decision::Invalid) { escalate(body: "Here is an answer.") }
  end

  def test_rejects_unknown_status
    error = assert_raises(Runes::Swarm::Decision::Invalid) do
      Runes::Swarm::Decision.new(status: :retry, reason_code: :low_confidence)
    end
    assert_includes error.message, "unknown status"
  end

  def test_rejects_unknown_reason_code
    error = assert_raises(Runes::Swarm::Decision::Invalid) do
      decline(reason_code: :because)
    end
    assert_includes error.message, "unknown reason_code"
  end

  def test_rejects_unknown_next_hop
    error = assert_raises(Runes::Swarm::Decision::Invalid) do
      escalate(next_hop: :generalist)
    end
    assert_includes error.message, "unknown next_hop"
  end

  def test_rejects_non_string_body_and_message
    assert_raises(Runes::Swarm::Decision::Invalid) { accept(body: 42) }
    assert_raises(Runes::Swarm::Decision::Invalid) { decline(message: 42) }
  end

  def test_from_h_rejects_unknown_keys
    data = decline.to_h.merge("retry" => true)

    error = assert_raises(Runes::Swarm::Decision::Invalid) do
      Runes::Swarm::Decision.from_h(data)
    end
    assert_includes error.message, "unknown keys"
  end

  def test_from_h_requires_status_and_reason
    data = decline.to_h
    data.delete("reason_code")

    error = assert_raises(Runes::Swarm::Decision::Invalid) do
      Runes::Swarm::Decision.from_h(data)
    end
    assert_includes error.message, "missing keys"
  end
end
