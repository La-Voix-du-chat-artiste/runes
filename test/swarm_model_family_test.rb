# frozen_string_literal: true

require_relative "test_helper"
require_relative "../lib/runes"

class SwarmModelFamilyTest < Minitest::Test
  def family(model)
    Runes::Swarm::ModelFamily.fetch(model)
  end

  def test_fetches_each_checkpoint
    %w[
      ruby external LiquidAI/LFM3-1.7B LiquidAI/LFM3-1.7B-Base
      LiquidAI/LFM3-VL-2B LiquidAI/LFM3-Audio-2B LiquidAI/LFM3-Omni-2B
      LiquidAI/d1-2B LiquidAI/d1-Omni-2B
    ].each do |model|
      assert_equal model, family(model).model
    end
  end

  def test_rejects_an_unknown_model
    error = assert_raises(Runes::Swarm::ModelFamily::Invalid) do
      family("LiquidAI/LFM4-99B")
    end
    assert_includes error.message, "unknown model"
  end

  def test_role_models_are_the_ones_the_cards_recommend
    assert_equal ["ruby"], Runes::Swarm::ModelFamily.models_for(:planner)
    assert_equal ["ruby"], Runes::Swarm::ModelFamily.models_for(:reviewer)
    assert_equal %w[LiquidAI/d1-2B LiquidAI/d1-Omni-2B],
                 Runes::Swarm::ModelFamily.models_for(:triage)
    assert_equal ["LiquidAI/LFM3-VL-2B"], Runes::Swarm::ModelFamily.models_for(:vision)
    assert_equal ["LiquidAI/LFM3-Audio-2B"], Runes::Swarm::ModelFamily.models_for(:audio)
    assert_equal ["LiquidAI/LFM3-Omni-2B"], Runes::Swarm::ModelFamily.models_for(:omni)
    assert_equal %w[LiquidAI/LFM3-1.7B LiquidAI/LFM3-1.7B-Base],
                 Runes::Swarm::ModelFamily.models_for(:answerer)
  end

  def test_allowed_pairs_are_strict
    assert Runes::Swarm::ModelFamily.allowed?(role: :answerer, model: "LiquidAI/LFM3-1.7B")
    assert Runes::Swarm::ModelFamily.allowed?(role: :vision, model: "LiquidAI/LFM3-VL-2B")
    refute Runes::Swarm::ModelFamily.allowed?(role: :vision, model: "LiquidAI/LFM3-1.7B")
    refute Runes::Swarm::ModelFamily.allowed?(role: :answerer, model: "LiquidAI/d1-2B")
  end

  def test_schemas_are_role_specific
    assert_equal "verdict.v1", Runes::Swarm::ModelFamily.schema_for(:triage)
    assert_equal "perception.v1", Runes::Swarm::ModelFamily.schema_for(:vision)
    assert_equal "proposal.v1", Runes::Swarm::ModelFamily.schema_for(:ideator)
    assert_equal "plan.v1", Runes::Swarm::ModelFamily.schema_for(:planner)
    assert_equal "review.v1", Runes::Swarm::ModelFamily.schema_for(:reviewer)
    assert_equal "answer.v1", Runes::Swarm::ModelFamily.schema_for(:repairer)
  end

  def test_deterministic_and_external_roles
    assert Runes::Swarm::ModelFamily.deterministic?(:conductor)
    assert Runes::Swarm::ModelFamily.deterministic?(:planner)
    assert Runes::Swarm::ModelFamily.deterministic?(:reviewer)
    assert Runes::Swarm::ModelFamily.deterministic?(:verifier)
    refute Runes::Swarm::ModelFamily.deterministic?(:answerer)
    assert Runes::Swarm::ModelFamily.external?(:escalation)
    refute Runes::Swarm::ModelFamily.external?(:answerer)
  end

  def test_modalities_and_context
    vl = family("LiquidAI/LFM3-VL-2B")
    assert_equal %i[text image video], vl.modalities
    assert_equal 131_072, vl.context_tokens
    assert vl.accepts_modality?(:image)
    refute vl.accepts_modality?(:audio)

    audio = family("LiquidAI/LFM3-Audio-2B")
    assert_equal %i[text audio], audio.modalities
    assert_equal 32_768, audio.context_tokens

    omni = family("LiquidAI/LFM3-Omni-2B")
    assert_equal %i[text image video audio], omni.modalities
  end

  def test_envelope_mode_and_token_generation
    assert family("LiquidAI/LFM3-1.7B").echo?
    refute family("LiquidAI/LFM3-1.7B").stamp?
    assert family("LiquidAI/d1-2B").stamp?
    assert family("LiquidAI/d1-2B").structured?
    refute family("LiquidAI/d1-2B").generates_tokens?
    assert family("LiquidAI/LFM3-VL-2B").generates_tokens?
    refute family("ruby").generates_tokens?
  end

  def test_to_h_round_trips_through_json
    value = family("LiquidAI/LFM3-Omni-2B")
    parsed = Runes::Json.parse(Runes::Json.generate(value.to_h))

    assert_equal value.to_h, parsed
  end
end
