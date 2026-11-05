# frozen_string_literal: true

require_relative "test_helper"
require_relative "../lib/runes"

class SwarmEnvelopeTest < Minitest::Test
  def identity_block
    <<~IDENTITY
      ### IDENTITY
      agent_id: answerer.grounded
      version: 1.0.0
      role: answerer
      base_model: LiquidAI/LFM3-1.7B
      adapter: prompt:grounded-qa-v1
      adapter_sha256: null
    IDENTITY
  end

  def capacity_block
    <<~CAPACITIES
      ### CAPACITIES
      can: read_evidence, answer_fr, cite
      cannot: retrieve, execute_tools, write_code
      max_input_tokens: 262144
      max_output_tokens: 320
      output_schema: answer.v1
    CAPACITIES
  end

  def decision_block(status: "accept", reason: "ok", hop: "null")
    <<~DECISION
      ### DECISION
      status: #{status}
      reason_code: #{reason}
      next: #{hop}
      message: done
    DECISION
  end

  def full_text(body: "The room has two windows.\n")
    "#{identity_block}\n#{capacity_block}\n#{decision_block}\n### BODY\n#{body}"
  end

  def test_parses_markdown_headings
    envelope = Runes::Swarm::Envelope.parse(full_text)

    assert envelope.present?
    assert envelope.complete?
    assert_instance_of Runes::Swarm::Identity, envelope.identity
    assert_equal "answerer.grounded", envelope.identity.agent_id
    assert_instance_of Runes::Swarm::Capacity, envelope.capacity
    assert_equal %i[read_evidence answer_fr cite], envelope.capacity.can
    assert_instance_of Runes::Swarm::Decision, envelope.decision
    assert envelope.decision.accept?
    assert_equal "The room has two windows.", envelope.body
    assert envelope.body_present?
  end

  def test_accepts_bold_and_colon_headings
    text = full_text
           .sub("### IDENTITY", "**IDENTITY**")
           .sub("### CAPACITIES", "CAPACITIES:")
           .sub("### DECISION", "**DECISION**")

    envelope = Runes::Swarm::Envelope.parse(text)

    assert_equal "answerer.grounded", envelope.identity.agent_id
    assert_equal "answer.v1", envelope.capacity.output_schema
    assert envelope.decision.accept?
  end

  def test_accepts_the_json_form
    payload = {
      "identity" => {
        "agent_id" => "answerer.grounded",
        "version" => "1.0.0",
        "role" => "answerer",
        "base_model" => "LiquidAI/LFM3-1.7B",
        "adapter" => "prompt:grounded-qa-v1",
        "adapter_sha256" => nil
      },
      "capacities" => {
        "can" => %w[read_evidence answer_fr cite],
        "cannot" => %w[retrieve execute_tools write_code],
        "max_input_tokens" => 262_144,
        "max_output_tokens" => 320,
        "output_schema" => "answer.v1"
      },
      "decision" => { "status" => "accept", "reason_code" => "ok", "next" => nil },
      "body" => "The room has two windows."
    }

    envelope = Runes::Swarm::Envelope.parse(Runes::Json.generate(payload))

    assert envelope.complete?
    assert_equal "answerer.grounded", envelope.identity.agent_id
    assert_equal "The room has two windows.", envelope.body
  end

  def test_missing_envelope_returns_nil_fields_not_an_exception
    envelope = Runes::Swarm::Envelope.parse("The room has two windows.")

    assert envelope.empty?
    refute envelope.present?
    assert_nil envelope.identity
    assert_nil envelope.capacity
    assert_nil envelope.decision
    assert_equal "", envelope.body
    refute envelope.complete?
  end

  def test_missing_body_is_empty_and_a_decline_still_parses
    text = "#{identity_block}\n#{capacity_block}\n#{decision_block(status: 'decline', reason: 'missing_evidence', hop: 'human')}"

    envelope = Runes::Swarm::Envelope.parse(text)

    refute envelope.body_present?
    assert_equal "", envelope.body
    assert envelope.decision.decline?
    assert envelope.complete?
  end

  def test_an_accept_without_a_body_has_no_decision_object
    text = "#{identity_block}\n#{capacity_block}\n#{decision_block}"

    envelope = Runes::Swarm::Envelope.parse(text)

    assert_equal "accept", envelope.decision_fields["status"]
    assert_nil envelope.decision
    assert_includes envelope.decision_error, "non-empty body"
    refute envelope.complete?
  end

  def test_a_fenced_body_is_preserved
    body = "```ruby\nputs \"hi\"\n```\n"
    envelope = Runes::Swarm::Envelope.parse(full_text(body: body))

    assert_includes envelope.body, "```ruby"
    assert_includes envelope.body, "puts \"hi\""
  end

  def test_body_headings_do_not_corrupt_the_decision
    body = "### Citations\nbook/chapter/code\n"
    envelope = Runes::Swarm::Envelope.parse(full_text(body: body))

    assert envelope.decision.accept?
    assert_includes envelope.body, "### Citations"
    assert_includes envelope.body, "book/chapter/code"
  end

  def test_next_and_next_hop_are_aliases
    scout_text = "#{identity_block}\n#{capacity_block}\n#{decision_block(status: 'decline', reason: 'missing_evidence', hop: 'scout')}"
    human_text = "#{identity_block}\n#{capacity_block}\n#{decision_block(status: 'escalate', reason: 'needs_human', hop: 'human')}"
           .sub("next: human", "next_hop: human")

    assert_equal :scout, Runes::Swarm::Envelope.parse(scout_text).decision.next_hop
    assert_equal :human, Runes::Swarm::Envelope.parse(human_text).decision.next_hop
  end

  def test_capacity_lists_accept_brackets_quotes_and_commas
    text = full_text.sub(
      "can: read_evidence, answer_fr, cite",
      'can: ["read_evidence", "answer_fr", "cite"]'
    )

    envelope = Runes::Swarm::Envelope.parse(text)

    assert_equal %i[read_evidence answer_fr cite], envelope.capacity.can
  end

  def test_think_tags_are_ignored
    text = "<think>internal plan</think>\n#{full_text}"
    envelope = Runes::Swarm::Envelope.parse(text)

    assert envelope.complete?
    refute_includes envelope.body, "internal plan"
  end

  def test_an_invalid_identity_block_is_reported_not_raised
    text = full_text.sub("version: 1.0.0", "version: nope")
    envelope = Runes::Swarm::Envelope.parse(text)

    assert_nil envelope.identity
    assert_includes envelope.identity_error, "invalid version"
    assert envelope.present?
    refute envelope.complete?
  end
end
