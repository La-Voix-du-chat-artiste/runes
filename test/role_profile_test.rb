# frozen_string_literal: true

require_relative "test_helper"
require_relative "../lib/runes"

class RoleProfileTest < Minitest::Test
  def manifest(name)
    Runes::Swarm::Manifest.load(File.join(__dir__, "..", "config", "agents", name))
  end

  def test_the_prompt_contains_the_assigned_identity_and_capacities
    assigned = manifest("answerer.json")
    profile = Runes::LLM::RoleProfile.for(
      assigned,
      instructions: "Answer only from the evidence."
    )

    prompt = profile.prompt(
      task: "Quel est le total ?",
      evidence: { "page:1" => "Total 128,40 EUR" }
    )

    assert_includes prompt, "agent_id: answerer.grounded"
    assert_includes prompt, "version: 1.0.0"
    assert_includes prompt, "adapter: prompt:grounded-qa-v1"
    assert_includes prompt, "output_schema: answer.v1"
    assert_includes prompt, "max_output_tokens: 320"
    assert_includes prompt, "can: read_evidence, answer_fr, answer_en, cite, abstain, decline"
    assert_includes prompt, "cannot: retrieve, execute_tools, write_code"
    assert_includes prompt, "assigned by the adapter"
    assert_includes prompt, "Return exactly two blocks"
    assert_includes prompt, "status: decline"
    assert_includes prompt, "Quel est le total ?"
    assert_includes prompt, "128,40 EUR"
    assert_operator prompt.index("### IDENTITY"), :<, prompt.index("### CAPACITIES")
    assert_operator prompt.index("### CAPACITIES"), :<, prompt.index("### INSTRUCTIONS")
    assert_operator prompt.index("### INSTRUCTIONS"), :<, prompt.index("### TASK")
  end

  def test_per_role_max_tokens_come_from_the_manifest
    answerer = Runes::LLM::RoleProfile.for(manifest("answerer.json"))
    ideator = Runes::LLM::RoleProfile.for(manifest("ideator_direct.json"))

    assert_equal 320, answerer.max_tokens
    assert_equal 512, ideator.max_tokens
    assert_equal 512, ideator.to_h["max_tokens"]
  end

  def test_tools_are_listed_only_for_the_scout
    scout = Runes::LLM::RoleProfile.for(
      manifest("scout.json"),
      tools: ["retrieve", "execute_tools"]
    )
    answerer = Runes::LLM::RoleProfile.for(
      manifest("answerer.json"),
      tools: ["retrieve"]
    )

    scout_prompt = scout.prompt(task: "find evidence")
    answerer_prompt = answerer.prompt(task: "answer")

    assert_includes scout_prompt, "### TOOLS"
    assert_includes scout_prompt, "- retrieve"
    assert_includes scout_prompt, "- execute_tools"
    assert_equal ["retrieve", "execute_tools"], scout.tools

    refute_includes answerer_prompt, "### TOOLS"
    assert_empty answerer.tools
  end

  def test_stamp_mode_omits_the_echo_request
    profile = Runes::LLM::RoleProfile.for(manifest("triage.json"))

    prompt = profile.prompt(task: "Is this in scope?")
    typed = profile.prompt(
      task: "Score scope",
      questions: [{ "id" => "scope", "question" => "In scope?" }]
    )

    assert profile.stamp?
    refute profile.echo?
    refute_includes prompt, "Copy the assigned values exactly"
    refute_includes prompt, "### DECISION"
    assert_includes prompt, "the adapter stamps"
    assert_includes prompt, "agent_id: triage.d1"
    assert_includes typed, "### QUESTIONS"
    assert_includes typed, "In scope?"
  end

  def test_echo_mode_is_the_default_for_text_roles
    profile = Runes::LLM::RoleProfile.for(manifest("critic.json"))

    assert profile.echo?
    refute profile.stamp?
    assert_includes profile.prompt(task: "audit"), "### DECISION"
  end

  def test_a_profile_without_a_manifest_uses_the_explicit_adapter_hash
    digest = "a" * 64
    profile = Runes::LLM::RoleProfile.new(
      role: :answerer,
      instructions: "Answer.",
      adapter: "prompt:custom-v1",
      adapter_sha256: digest
    )

    assert_equal digest, profile.identity.adapter_sha256
    prompt = profile.prompt(task: "task")
    assert_includes prompt, "adapter: prompt:custom-v1"
    assert_includes prompt, "adapter_sha256: #{digest}"
    assert_equal 320, profile.max_tokens
  end

  def test_stamp_mode_can_override_the_manifest_family_mode
    profile = Runes::LLM::RoleProfile.for(
      manifest("answerer.json"),
      envelope_mode: :stamp
    )

    assert profile.stamp?
    refute_includes profile.prompt(task: "task"), "Copy the assigned values exactly"
  end

  def test_json_packets_are_rendered_as_json
    profile = Runes::LLM::RoleProfile.for(manifest("answerer.json"))
    packet = { "anchors" => ["page:1"], "fields" => { "total" => "128,40" } }

    prompt = profile.prompt(task: "total?", evidence: packet)

    parsed = prompt.split("### EVIDENCE\n", 2).last.split("\n", 2).first
    assert_equal packet, Runes::Json.parse(parsed)
  end
end
