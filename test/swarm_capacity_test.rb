# frozen_string_literal: true

require_relative "test_helper"
require_relative "../lib/runes"

class SwarmCapacityTest < Minitest::Test
  def build(overrides = {})
    defaults = {
      can: %i[read_evidence answer_fr cite abstain decline],
      cannot: %i[retrieve execute_tools write_code verify_own_citations],
      max_input_tokens: 262_144,
      max_output_tokens: 320,
      output_schema: "answer.v1"
    }
    Runes::Swarm::Capacity.new(**defaults.merge(overrides))
  end

  def test_allows_and_forbids
    capacity = build

    assert capacity.allows?(:cite)
    assert capacity.allows?("cite")
    assert capacity.forbids?(:execute_tools)
    assert capacity.forbids?("execute_tools")
    refute capacity.allows?(:execute_tools)
    refute capacity.forbids?(:cite)
    refute capacity.allows?(:not_declared)
    refute capacity.forbids?(:not_declared)
  end

  def test_overreach_returns_claimed_capabilities_outside_can
    assert_equal %i[write_code], build.overreach(%i[cite write_code])
    assert_equal %i[write_code], build.overreach(%w[cite write_code])
    assert_empty build.overreach(%i[cite abstain])
    assert_empty build.overreach(nil)
  end

  def test_missing_returns_required_capabilities_not_granted
    assert_equal %i[retrieve], build.missing(%i[cite retrieve])
    assert_equal %i[retrieve], build.missing(%w[cite retrieve])
    assert_empty build.missing(%i[cite abstain])
    assert_empty build.missing(nil)
  end

  def test_subset_of
    smaller = build(can: %i[read_evidence cite], cannot: %i[retrieve])

    assert smaller.subset_of?(build)
    refute build.subset_of?(smaller)
    assert build.subset_of?(build)
  end

  def test_subset_of_rejects_a_non_capacity
    assert_raises(Runes::Swarm::Capacity::Invalid) { build.subset_of?(:not_a_capacity) }
  end

  def test_to_h_is_string_keyed_and_round_trips
    capacity = build

    assert_equal(
      {
        "can" => %w[read_evidence answer_fr cite abstain decline],
        "cannot" => %w[retrieve execute_tools write_code verify_own_citations],
        "max_input_tokens" => 262_144,
        "max_output_tokens" => 320,
        "output_schema" => "answer.v1"
      },
      capacity.to_h
    )
    assert_equal capacity, Runes::Swarm::Capacity.from_h(capacity.to_h)
    assert_equal capacity, Runes::Swarm::Capacity.from_h(capacity.to_h.transform_keys(&:to_sym))
  end

  def test_string_capabilities_are_normalized_to_symbols
    capacity = build(can: %w[cite], cannot: %w[retrieve])

    assert_equal %i[cite], capacity.can
    assert_equal %i[retrieve], capacity.cannot
  end

  def test_duplicate_capabilities_are_removed
    assert_equal %i[cite], build(can: %i[cite cite], cannot: %i[retrieve]).can
  end

  def test_zero_output_tokens_is_allowed_at_the_capacity_layer
    assert_equal 0, build(max_output_tokens: 0).max_output_tokens
  end

  def test_capacity_is_immutable
    capacity = build

    assert capacity.frozen?
    assert capacity.can.frozen?
    assert capacity.cannot.frozen?
    assert_raises(FrozenError) { capacity.can << :new_capability }
  end

  def test_rejects_empty_can
    error = assert_raises(Runes::Swarm::Capacity::Invalid) { build(can: []) }
    assert_includes error.message, "can must not be empty"
  end

  def test_rejects_empty_cannot
    error = assert_raises(Runes::Swarm::Capacity::Invalid) { build(cannot: []) }
    assert_includes error.message, "cannot must not be empty"
  end

  def test_rejects_overlap
    error = assert_raises(Runes::Swarm::Capacity::Invalid) do
      build(can: %i[cite execute_tools], cannot: %i[execute_tools])
    end
    assert_includes error.message, "overlap"
    assert_includes error.message, "execute_tools"
  end

  def test_rejects_negative_tokens
    assert_raises(Runes::Swarm::Capacity::Invalid) { build(max_input_tokens: -1) }
    assert_raises(Runes::Swarm::Capacity::Invalid) { build(max_output_tokens: -1) }
  end

  def test_rejects_non_integer_tokens
    assert_raises(Runes::Swarm::Capacity::Invalid) { build(max_input_tokens: "262144") }
    assert_raises(Runes::Swarm::Capacity::Invalid) { build(max_output_tokens: 3.5) }
  end

  def test_rejects_unknown_output_schema
    error = assert_raises(Runes::Swarm::Capacity::Invalid) { build(output_schema: "answer.v2") }
    assert_includes error.message, "unknown output_schema"
  end

  def test_from_h_rejects_unknown_and_missing_keys
    capacity = build

    unknown = capacity.to_h.merge("temperature" => 0.1)
    error = assert_raises(Runes::Swarm::Capacity::Invalid) do
      Runes::Swarm::Capacity.from_h(unknown)
    end
    assert_includes error.message, "unknown keys"

    missing = capacity.to_h
    missing.delete("output_schema")
    error = assert_raises(Runes::Swarm::Capacity::Invalid) do
      Runes::Swarm::Capacity.from_h(missing)
    end
    assert_includes error.message, "missing keys"
  end
end
