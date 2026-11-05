# frozen_string_literal: true

require_relative "test_helper"
require_relative "../lib/runes"

class SwarmManifestTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  AGENTS = File.join(ROOT, "config/agents")

  def setup
    @dir = Dir.mktmpdir("runes-swarm-manifest-")
  end

  def teardown
    FileUtils.remove_entry(@dir, true) if @dir && Dir.exist?(@dir)
  end

  def valid_manifest(overrides = {})
    data = {
      "agent_id" => "answerer.grounded",
      "version" => "1.0.0",
      "role" => "answerer",
      "base_model" => "LiquidAI/LFM3-1.7B",
      "adapter" => "prompt:grounded-qa-v1",
      "adapter_sha256" => nil,
      "capacities" => {
        "can" => %w[read_evidence answer_fr cite],
        "cannot" => %w[retrieve execute_tools write_code],
        "max_input_tokens" => 262_144,
        "max_output_tokens" => 320,
        "output_schema" => "answer.v1"
      },
      "requires_evidence" => true,
      "forbidden_actions" => %w[retrieve execute_tools write_code]
    }

    overrides.each do |key, value|
      if key.to_s == "capacities"
        data["capacities"] = data["capacities"].merge(value)
      else
        data[key.to_s] = value
      end
    end
    data
  end

  def conductor_manifest(overrides = {})
    valid_manifest(
      {
        agent_id: "conductor.router",
        role: "conductor",
        base_model: "ruby",
        adapter: "deterministic:router-v1",
        capacities: {
          "can" => %w[route],
          "cannot" => %w[answer],
          "max_output_tokens" => 0,
          "output_schema" => "decision.v1"
        },
        requires_evidence: false,
        forbidden_actions: %w[answer]
      }.merge(overrides)
    )
  end

  def write_manifest(name, data)
    path = File.join(@dir, "#{name}.json")
    File.write(path, Runes::Json.generate(data))
    path
  end

  def test_loads_the_nineteen_production_manifests
    manifests = Runes::Swarm::Manifest.load_all(AGENTS)

    assert_equal 19, manifests.size
    assert_equal(
      %w[
        answerer.grounded perceiver.audio conductor.router critic.claims
        escalation.frontier finalizer.concise ideator.alternative ideator.direct
        judge.d1 judge.omni perceiver.omni planner.microstep repairer.bounded
        reviewer.manager scout.retriever triage.d1 triage.audio
        verifier.mechanical perceiver.vision
      ],
      manifests.map(&:agent_id)
    )
    assert_equal(
      %i[
        answerer audio conductor critic escalation finalizer ideator ideator
        judge judge omni planner repairer reviewer scout triage triage verifier
        vision
      ],
      manifests.map(&:role)
    )
    manifests.each do |manifest|
      assert_instance_of Runes::Swarm::Identity, manifest.identity
      assert_instance_of Runes::Swarm::Capacity, manifest.capacity
      assert_instance_of Runes::Swarm::ModelFamily, manifest.family
      assert manifest.path.end_with?(".json")
    end
  end

  def test_deterministic_roles_use_ruby_and_zero_output_tokens
    manifests = Runes::Swarm::Manifest.load_all(AGENTS)

    %i[conductor planner reviewer verifier].each do |role|
      manifest = manifests.find { |candidate| candidate.role == role }
      assert manifest.deterministic?
      assert_equal "ruby", manifest.base_model
      assert_equal 0, manifest.capacity.max_output_tokens
    end
  end

  def test_model_roles_use_lfm3_and_a_positive_output_budget
    manifests = Runes::Swarm::Manifest.load_all(AGENTS)

    %i[scout answerer critic finalizer ideator repairer].each do |role|
      manifest = manifests.find { |candidate| candidate.role == role }
      refute manifest.deterministic?
      assert_equal "LiquidAI/LFM3-1.7B", manifest.base_model
      assert_operator manifest.capacity.max_output_tokens, :>, 0
    end
  end

  def test_each_role_family_uses_the_model_its_card_recommends
    manifests = Runes::Swarm::Manifest.load_all(AGENTS)

    {
      "triage.d1" => "LiquidAI/d1-2B",
      "triage.audio" => "LiquidAI/d1-Omni-2B",
      "judge.d1" => "LiquidAI/d1-2B",
      "judge.omni" => "LiquidAI/d1-Omni-2B",
      "perceiver.vision" => "LiquidAI/LFM3-VL-2B",
      "perceiver.audio" => "LiquidAI/LFM3-Audio-2B",
      "perceiver.omni" => "LiquidAI/LFM3-Omni-2B"
    }.each do |agent_id, model|
      assert_equal model, manifests.find { |m| m.agent_id == agent_id }.base_model
    end
  end

  def test_structured_roles_use_zero_output_tokens
    manifests = Runes::Swarm::Manifest.load_all(AGENTS)

    %w[triage.d1 triage.audio judge.d1 judge.omni].each do |agent_id|
      manifest = manifests.find { |m| m.agent_id == agent_id }
      refute manifest.deterministic?
      assert_equal 0, manifest.capacity.max_output_tokens
      assert manifest.family.structured?
    end
  end

  def test_escalation_role_uses_the_external_base_model
    manifest = Runes::Swarm::Manifest.load_all(AGENTS).find { |candidate| candidate.role == :escalation }

    assert_equal "external", manifest.base_model
    assert_equal "answer.v1", manifest.capacity.output_schema
    assert_operator manifest.capacity.max_output_tokens, :>, 0
  end

  def test_evidence_requirement_is_declared_per_role
    manifests = Runes::Swarm::Manifest.load_all(AGENTS)

    assert manifests.find { |m| m.role == :answerer }.requires_evidence?
    assert manifests.find { |m| m.role == :critic }.requires_evidence?
    assert manifests.find { |m| m.role == :finalizer }.requires_evidence?
    assert manifests.find { |m| m.role == :ideator }.requires_evidence?
    assert manifests.find { |m| m.role == :repairer }.requires_evidence?
    assert manifests.find { |m| m.role == :judge }.requires_evidence?
    refute manifests.find { |m| m.role == :conductor }.requires_evidence?
    refute manifests.find { |m| m.role == :planner }.requires_evidence?
    refute manifests.find { |m| m.role == :reviewer }.requires_evidence?
    refute manifests.find { |m| m.role == :verifier }.requires_evidence?
    refute manifests.find { |m| m.role == :vision }.requires_evidence?
  end

  def test_load_returns_identity_capacity_and_forbidden_actions
    path = File.join(AGENTS, "answerer.json")
    manifest = Runes::Swarm::Manifest.load(path)

    assert_equal "answerer.grounded", manifest.agent_id
    assert_equal "1.0.0", manifest.version
    assert_equal :answerer, manifest.role
    assert_equal "prompt:grounded-qa-v1", manifest.adapter
    assert_nil manifest.adapter_sha256
    assert_equal(
      %i[retrieve execute_tools write_code verify_own_citations critique rewrite],
      manifest.forbidden_actions
    )
    assert_equal path, manifest.path
  end

  def test_to_h_round_trips
    manifest = Runes::Swarm::Manifest.load(File.join(AGENTS, "critic.json"))

    assert_equal manifest, Runes::Swarm::Manifest.from_h(manifest.to_h)
  end

  def test_rejects_duplicate_agent_ids_across_a_directory
    write_manifest("one", valid_manifest)
    write_manifest(
      "two",
      valid_manifest(
        role: "critic",
        capacities: {
          "can" => %w[read_evidence audit_claims],
          "cannot" => %w[retrieve],
          "output_schema" => "critique.v1"
        },
        forbidden_actions: %w[retrieve]
      )
    )

    error = assert_raises(Runes::Swarm::Manifest::Invalid) do
      Runes::Swarm::Manifest.load_all(@dir)
    end
    assert_includes error.message, "duplicate agent_id"
    assert_includes error.message, "answerer.grounded"
  end

  def test_rejects_a_forbidden_action_outside_cannot
    error = assert_raises(Runes::Swarm::Manifest::Invalid) do
      Runes::Swarm::Manifest.from_h(valid_manifest(forbidden_actions: %w[answer]))
    end
    assert_includes error.message, "forbidden_actions outside cannot"
    assert_includes error.message, "answer"
  end

  def test_rejects_the_wrong_base_model_for_a_deterministic_role
    data = conductor_manifest(base_model: "LiquidAI/LFM3-1.7B")

    error = assert_raises(Runes::Swarm::Manifest::Invalid) do
      Runes::Swarm::Manifest.from_h(data)
    end
    assert_includes error.message, "requires base_model \"ruby\""
  end

  def test_rejects_zero_output_tokens_for_a_model_backed_role
    data = valid_manifest(capacities: { "max_output_tokens" => 0 })

    error = assert_raises(Runes::Swarm::Manifest::Invalid) do
      Runes::Swarm::Manifest.from_h(data)
    end
    assert_includes error.message, "requires max_output_tokens > 0"
  end

  def test_rejects_positive_output_tokens_for_a_deterministic_role
    data = conductor_manifest
    data["capacities"]["max_output_tokens"] = 320

    error = assert_raises(Runes::Swarm::Manifest::Invalid) do
      Runes::Swarm::Manifest.from_h(data)
    end
    assert_includes error.message, "must use max_output_tokens: 0"
  end

  def test_rejects_an_unknown_role
    error = assert_raises(Runes::Swarm::Manifest::Invalid) do
      Runes::Swarm::Manifest.from_h(valid_manifest(role: "janitor"))
    end
    assert_includes error.message, "unknown role"
  end

  def test_rejects_a_bad_adapter_hash
    error = assert_raises(Runes::Swarm::Manifest::Invalid) do
      Runes::Swarm::Manifest.from_h(valid_manifest(adapter_sha256: "A" * 64))
    end
    assert_includes error.message, "adapter_sha256"
  end

  def test_rejects_a_missing_required_key
    data = valid_manifest
    data.delete("capacities")

    error = assert_raises(Runes::Swarm::Manifest::Invalid) do
      Runes::Swarm::Manifest.from_h(data)
    end
    assert_includes error.message, "missing keys"
    assert_includes error.message, "capacities"
  end

  def test_rejects_a_non_boolean_requires_evidence
    error = assert_raises(Runes::Swarm::Manifest::Invalid) do
      Runes::Swarm::Manifest.from_h(valid_manifest(requires_evidence: "yes"))
    end
    assert_includes error.message, "requires_evidence must be true or false"
  end

  def test_rejects_an_unknown_top_level_key
    error = assert_raises(Runes::Swarm::Manifest::Invalid) do
      Runes::Swarm::Manifest.from_h(valid_manifest(temperature: 0.1))
    end
    assert_includes error.message, "unknown keys"
    assert_includes error.message, "temperature"
  end

  def test_rejects_an_unknown_capacity_schema
    error = assert_raises(Runes::Swarm::Manifest::Invalid) do
      Runes::Swarm::Manifest.from_h(valid_manifest(capacities: { "output_schema" => "answer.v2" }))
    end
    assert_includes error.message, "unknown output_schema"
  end

  def test_rejects_a_text_model_for_a_vision_role
    data = valid_manifest(
      agent_id: "perceiver.vision",
      role: "vision",
      capacities: {
        "can" => %w[read_image cite_anchors],
        "cannot" => %w[answer judge],
        "output_schema" => "perception.v1"
      },
      forbidden_actions: %w[answer judge]
    )

    error = assert_raises(Runes::Swarm::Manifest::Invalid) do
      Runes::Swarm::Manifest.from_h(data)
    end
    assert_includes error.message, "requires base_model"
    assert_includes error.message, "LiquidAI/LFM3-VL-2B"
  end

  def test_rejects_an_answer_schema_for_a_judge
    data = valid_manifest(
      agent_id: "judge.d1",
      role: "judge",
      base_model: "LiquidAI/d1-2B",
      capacities: {
        "can" => %w[score_support],
        "cannot" => %w[answer],
        "max_input_tokens" => 131_072,
        "max_output_tokens" => 0,
        "output_schema" => "answer.v1"
      },
      forbidden_actions: %w[answer]
    )

    error = assert_raises(Runes::Swarm::Manifest::Invalid) do
      Runes::Swarm::Manifest.from_h(data)
    end
    assert_includes error.message, "requires output_schema \"verdict.v1\""
  end

  def test_the_base_model_requires_an_adapter_hash
    data = valid_manifest(
      base_model: "LiquidAI/LFM3-1.7B-Base",
      adapter_sha256: nil
    )

    error = assert_raises(Runes::Swarm::Manifest::Invalid) do
      Runes::Swarm::Manifest.from_h(data)
    end
    assert_includes error.message, "requires a non-nil adapter_sha256"
  end

  def test_the_base_model_is_allowed_with_an_adapter_hash
    data = valid_manifest(
      base_model: "LiquidAI/LFM3-1.7B-Base",
      adapter_sha256: "a" * 64
    )

    manifest = Runes::Swarm::Manifest.from_h(data)

    assert_equal "LiquidAI/LFM3-1.7B-Base", manifest.base_model
  end

  def test_rejects_a_context_window_larger_than_the_family
    data = valid_manifest(
      role: "vision",
      agent_id: "perceiver.vision",
      base_model: "LiquidAI/LFM3-VL-2B",
      capacities: {
        "can" => %w[read_image cite_anchors],
        "cannot" => %w[answer judge],
        "max_input_tokens" => 262_144,
        "max_output_tokens" => 512,
        "output_schema" => "perception.v1"
      },
      forbidden_actions: %w[answer judge]
    )

    error = assert_raises(Runes::Swarm::Manifest::Invalid) do
      Runes::Swarm::Manifest.from_h(data)
    end
    assert_includes error.message, "exceeds"
    assert_includes error.message, "131072"
  end

  def test_rejects_malformed_json
    path = File.join(@dir, "broken.json")
    File.write(path, "{not json")

    error = assert_raises(Runes::Swarm::Manifest::Invalid) do
      Runes::Swarm::Manifest.load(path)
    end
    assert_includes error.message, "not valid JSON"
  end

  def test_rejects_a_missing_file
    error = assert_raises(Runes::Swarm::Manifest::Invalid) do
      Runes::Swarm::Manifest.load(File.join(@dir, "missing.json"))
    end
    assert_includes error.message, "cannot read"
  end

  def test_load_all_returns_an_empty_array_for_an_empty_directory
    assert_empty Runes::Swarm::Manifest.load_all(@dir)
  end
end
