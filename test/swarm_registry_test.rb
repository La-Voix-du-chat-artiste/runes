# frozen_string_literal: true

require_relative "test_helper"
require_relative "../lib/runes"

class SwarmRegistryTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  AGENTS = File.join(ROOT, "config/agents")

  def setup
    @manifests = Runes::Swarm::Manifest.load_all(AGENTS)
    @registry = Runes::Swarm::Registry.new(@manifests)
  end

  def test_fetch_returns_a_manifest
    manifest = @registry.fetch("answerer.grounded")

    assert_instance_of Runes::Swarm::Manifest, manifest
    assert_equal :answerer, manifest.role
  end

  def test_fetch_is_nil_safe
    assert_nil @registry.fetch("missing.agent")
    assert_nil @registry.fetch(nil)
  end

  def test_fetch_bang_raises_for_an_unknown_agent
    error = assert_raises(Runes::Swarm::Registry::UnknownAgent) do
      @registry.fetch!("missing.agent")
    end
    assert_includes error.message, "missing.agent"
  end

  def test_by_role_returns_the_manifest
    assert_equal "critic.claims", @registry.by_role(:critic).agent_id
    assert_equal "critic.claims", @registry.by_role("critic").agent_id
  end

  def test_by_role_raises_for_an_unknown_role
    error = assert_raises(Runes::Swarm::Registry::UnknownRole) do
      @registry.by_role(:janitor)
    end
    assert_includes error.message, "janitor"
  end

  def test_roles_and_agent_ids_are_sorted
    assert_equal(
      %i[answerer audio conductor critic escalation finalizer ideator judge omni planner repairer reviewer scout triage verifier vision],
      @registry.roles
    )
    assert_equal 19, @registry.agent_ids.size
  end

  def test_size_and_enumerable
    assert_equal 19, @registry.size
    assert_equal 19, @registry.count
    refute @registry.empty?
    assert_equal 19, @registry.each.to_a.size
  end

  def test_manifests_returns_a_copy
    copy = @registry.manifests
    copy.clear

    assert_equal 19, @registry.size
    refute_same copy, @registry.manifests
  end

  def test_register_rejects_a_duplicate_agent_id
    registry = Runes::Swarm::Registry.new([@registry.by_role(:answerer)])

    error = assert_raises(Runes::Swarm::Registry::DuplicateAgent) do
      registry.register(@registry.by_role(:answerer))
    end
    assert_includes error.message, "answerer.grounded"
  end

  def test_register_allows_a_second_agent_in_the_same_role
    other = Runes::Swarm::Manifest.from_h(
      @registry.by_role(:answerer).to_h.merge(
        "agent_id" => "answerer.other",
        "adapter" => "prompt:other-answerer-v1"
      )
    )
    registry = Runes::Swarm::Registry.new([@registry.by_role(:answerer)])

    registry.register(other)

    assert_equal 2, registry.size
    assert_equal 2, registry.all_by_role(:answerer).size
    assert_equal "answerer.grounded", registry.by_role(:answerer).agent_id
  end

  def test_register_rejects_a_non_manifest
    error = assert_raises(Runes::Swarm::Registry::Error) do
      Runes::Swarm::Registry.new([:not_a_manifest])
    end
    assert_includes error.message, "expected a Manifest"
  end

  def test_register_returns_the_manifest_and_adds_it
    registry = Runes::Swarm::Registry.new
    manifest = @registry.by_role(:critic)

    assert_same manifest, registry.register(manifest)
    assert_equal 1, registry.size
    assert_equal manifest, registry.fetch("critic.claims")
  end

  def test_empty_registry
    registry = Runes::Swarm::Registry.new

    assert registry.empty?
    assert_equal 0, registry.size
    assert_empty registry.roles
    assert_empty registry.manifests
  end
end
