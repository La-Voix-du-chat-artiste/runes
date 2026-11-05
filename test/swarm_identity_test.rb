# frozen_string_literal: true

require_relative "test_helper"
require_relative "../lib/runes"

class SwarmIdentityTest < Minitest::Test
  SHA = "a" * 64

  def build(overrides = {})
    defaults = {
      agent_id: "answerer.grounded",
      version: "1.0.0",
      role: :answerer,
      base_model: "LiquidAI/LFM3-1.7B",
      adapter: "prompt:grounded-qa-v1",
      adapter_sha256: nil
    }
    Runes::Swarm::Identity.new(**defaults.merge(overrides))
  end

  def test_builds_a_valid_identity
    identity = build

    assert_equal "answerer.grounded", identity.agent_id
    assert_equal "1.0.0", identity.version
    assert_equal :answerer, identity.role
    assert_equal "LiquidAI/LFM3-1.7B", identity.base_model
    assert_equal "prompt:grounded-qa-v1", identity.adapter
    assert_nil identity.adapter_sha256
  end

  def test_to_h_is_string_keyed
    assert_equal(
      {
        "agent_id" => "answerer.grounded",
        "version" => "1.0.0",
        "role" => "answerer",
        "base_model" => "LiquidAI/LFM3-1.7B",
        "adapter" => "prompt:grounded-qa-v1",
        "adapter_sha256" => nil
      },
      build.to_h
    )
  end

  def test_role_is_normalized_to_a_symbol
    assert_equal :critic, build(role: "critic").role
  end

  def test_identity_is_immutable
    identity = build

    assert identity.frozen?
    assert identity.agent_id.frozen?
    assert identity.to_h.frozen? == false
    assert_raises(FrozenError) { identity.agent_id << "-changed" }
  end

  def test_value_equality_and_hash
    one = build
    two = build
    different = build(adapter_sha256: SHA)

    assert_equal one, two
    assert one.eql?(two)
    assert_equal one.hash, two.hash
    refute_equal one, different
  end

  def test_from_h_round_trips_string_keys
    identity = build(adapter_sha256: SHA)

    assert_equal identity, Runes::Swarm::Identity.from_h(identity.to_h)
  end

  def test_from_h_accepts_symbol_keys_and_defaults_missing_sha
    data = build.to_h.transform_keys(&:to_sym)
    data.delete(:adapter_sha256)

    identity = Runes::Swarm::Identity.from_h(data)

    assert_equal "answerer.grounded", identity.agent_id
    assert_nil identity.adapter_sha256
  end

  def test_from_h_rejects_unknown_keys
    data = build.to_h.merge("temperature" => 0.1)

    error = assert_raises(Runes::Swarm::Identity::Invalid) do
      Runes::Swarm::Identity.from_h(data)
    end
    assert_includes error.message, "unknown keys"
    assert_includes error.message, "temperature"
  end

  def test_from_h_rejects_missing_keys
    data = build.to_h
    data.delete("agent_id")

    error = assert_raises(Runes::Swarm::Identity::Invalid) do
      Runes::Swarm::Identity.from_h(data)
    end
    assert_includes error.message, "missing keys"
    assert_includes error.message, "agent_id"
  end

  def test_rejects_invalid_agent_id
    ["Answerer.grounded", "1answerer", "", " ", nil, 42].each do |value|
      assert_raises(Runes::Swarm::Identity::Invalid, "expected #{value.inspect} to be rejected") do
        build(agent_id: value)
      end
    end
  end

  def test_rejects_invalid_version
    ["1.0", "v1.0.0", "1.0.0-beta", "", nil].each do |value|
      assert_raises(Runes::Swarm::Identity::Invalid, "expected #{value.inspect} to be rejected") do
        build(version: value)
      end
    end
  end

  def test_rejects_unknown_role
    error = assert_raises(Runes::Swarm::Identity::Invalid) { build(role: :janitor) }
    assert_includes error.message, "unknown role"
  end

  def test_rejects_bad_adapter_sha256
    ["A" * 64, "a" * 63, "g" * 64, "a" * 65].each do |value|
      assert_raises(Runes::Swarm::Identity::Invalid, "expected #{value.inspect} to be rejected") do
        build(adapter_sha256: value)
      end
    end
  end

  def test_accepts_a_64_hex_adapter_sha256
    assert_equal SHA, build(adapter_sha256: SHA).adapter_sha256
  end
end
