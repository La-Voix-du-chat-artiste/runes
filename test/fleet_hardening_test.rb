# frozen_string_literal: true

require_relative "test_helper"

require "minitest/autorun"

require_relative "../lib/runes/fleet"
require_relative "../lib/runes/transport"
require_relative "../lib/runes/transport/in_process"
load File.expand_path("../bin/runes-acl", __dir__)

# The 0.4.x fleet hardening batch: declared payload schemas (§4.3,
# fail-closed), shared-group subscriptions (one runner per fleet for
# event sources), presence TRANSITIONS (§5.2 — retained replays are
# state, not news), and the fleet runtime's broker identity (§8.2 —
# exactly what the loaded rules publish, nothing more).
class FleetHardeningTest < Minitest::Test
  def fleet(src, args: {})
    Runes::Fleet.load(src, path: "(hardening-test)", args: args)
  end

  def header
    "# fleet-spec: 0.1\n"
  end

  def world_source(rules: "", extra: "")
    header + <<~'RUBY'
      fleet "hardened" do
        transport :inproc
        group "hardened-workers"
        channel :events, "runes/events/hardened", schema: :event
        channel :metrics, "runes/events/metrics"
        channel :dead_letter, "runes/events/dead"
        schema :event, {
          "required" => %w[email],
          "fields"   => { "email" => "string", "score" => "number", "tags" => "array" }
        }
        agent :worker do
          model "m"
          tools fs_read: :allow
        end
        agent :sink do
          model "m"
          tools :none
        end
        route :worker, :sink
      RUBY
           .then { |s| s + extra } +
      <<~'RUBY' + rules + "end\n"
        on :events do |e|
          task :sink, "handle %{email}"
          publish :metrics, { seen: true }
        end
      RUBY
  end

  # ---- declared schemas: fail-closed before any rule guard ----

  def test_schema_validates_and_refuses
    world = fleet(world_source)
    _engine, transport = setup_engine(world)
    engine = Runes::Fleet::Engine.new(world, transport: transport)
    engine.start
    dead = []
    transport.subscribe("runes/events/dead") { |m| dead << Runes::Json.parse(m.payload) }
    fired = []
    transport.subscribe("runes/events/metrics") { |m| fired << m }

    good = Runes::Json.generate({ "email" => "a@b.c", "score" => 0.5, "tags" => %w[x] })
    transport.publish("runes/events/hardened", good)
    assert_equal 1, fired.size, "valid payload fires"

    missing = Runes::Json.generate({ "score" => 0.5 })
    transport.publish("runes/events/hardened", missing)
    assert_equal 1, fired.size, "missing required field never reaches a rule"
    assert_equal "schema_refused", dead.last["event"]
    assert_match(/missing required field/, dead.last["reason"])

    wrong_type = Runes::Json.generate({ "email" => 1, "score" => "x" })
    transport.publish("runes/events/hardened", wrong_type)
    assert_equal 1, fired.size
    assert_match(/is not a string/, dead.last["reason"])
  end

  def test_schema_declaration_errors_are_load_errors
    assert_load_error(/undeclared schema/) do
      fleet(header + <<~'RUBY')
        fleet "x" do
          transport :inproc
          channel :c, "runes/events/c", schema: :ghost
        end
      RUBY
    end
    assert_load_error(/unknown field kind/) do
      fleet(header + <<~'RUBY')
        fleet "x" do
          transport :inproc
          schema :s, { "fields" => { "a" => "wat" } }
        end
      RUBY
    end
    assert_load_error(/must be a literal hash/) do
      fleet(header + <<~'RUBY')
        fleet "x" do
          transport :inproc
          schema :s, "nope"
        end
      RUBY
    end
  end

  # ---- shared group: N runners split events, none double-fires ----

  def test_two_runners_in_one_group_each_event_processed_once
    world = fleet(world_source)
    hub = Runes::Transport::InProcess::Hub.new(name: "hardening-#{object_id}-#{Runes::Random.hex(4)}")
    t1 = Runes::Transport::InProcess.new(hub: hub)
    t2 = Runes::Transport::InProcess.new(hub: hub)
    t1.connect
    t2.connect
    e1 = Runes::Fleet::Engine.new(world, transport: t1)
    e2 = Runes::Fleet::Engine.new(world, transport: t2)
    e1.start
    e2.start

    4.times do |i|
      t1.publish("runes/events/hardened", Runes::Json.generate({ "email" => "u#{i}@x.fr" }))
    end

    actions = ->(engine) { engine.journal.count { |j| j["kind"] == "action" } }
    total = actions.call(e1) + actions.call(e2)
    assert_equal 8, total, "4 events x 2 actions, each processed exactly once across the fleet (got #{total})"
    assert actions.call(e1).positive? && actions.call(e2).positive?, "both runners shared the work"
  end

  # ---- presence: transitions only, retained replays seed but never fire ----

  def test_presence_fires_only_on_real_transitions
    world = fleet(world_source(rules: <<~'RUBY'))
      on :agent_online do |e|
        notify "up: #{e.agent}", level: :info
      end
      on :agent_offline do |e|
        notify "down: #{e.agent}", level: :warn
      end
    RUBY
    _e, transport = setup_engine(world)
    engine = Runes::Fleet::Engine.new(world, transport: transport)
    engine.start
    notices = []
    engine.instance_variable_set(:@notifier, ->(n) { notices << n["text"] })

    transport.publish("runes/agents/ada/status", "online", retain: true)
    assert_empty notices, "a retained card replay is state, not news"

    transport.publish("runes/agents/ada/status", "online")
    assert_empty notices, "no transition: still online"

    transport.publish("runes/agents/ada/status", "offline")
    assert_equal ["down: ada"], notices

    transport.publish("runes/agents/ada/status", "offline")
    assert_equal ["down: ada"], notices, "no transition: still offline"

    transport.publish("runes/agents/ada/status", "online")
    assert_equal ["down: ada", "up: ada"], notices
  end

  # ---- the runtime's broker identity: exactly what the rules publish ----

  def test_runtime_acl_covers_only_what_rules_publish
    world = fleet(world_source)
    assert_equal "fleet-hardened", world.runtime_user
    writes = world.runtime_acl.to_h { |access, topic| [topic, access] }
    assert_equal "write", writes["runes/agents/sink/tasks"]
    assert_equal "write", writes["runes/events/metrics"]
    assert_equal "write", writes["runes/events/dead"]
    refute writes.key?("runes/agents/worker/tasks"), "the runtime may only task what rules task"
    refute writes.key?("#"), "no catch-all, ever"
  end

  def test_runes_acl_renders_the_runtime_user_section
    world = fleet(world_source)
    acl = Runes::Security::ACL.new(
      agents: world.roles.keys.map(&:to_s),
      fleet_grants: world.acl_extract,
      extra_users: { world.runtime_user => world.runtime_acl },
      fleet_note: "hardened (test)"
    )
    rendered = acl.render
    section = rendered.split(/^user /).find { |s| s.start_with?("fleet-hardened\n") }
    assert_includes section, "topic write runes/agents/sink/tasks"
    assert_includes section, "topic write runes/events/metrics"
    refute_includes section, "topic read"
    assert_includes rendered, "runtime — publishes only"
  end

  def test_runes_acl_rejects_bad_extra_user_grants
    err = assert_raises(Runes::Security::ACL::ACLError) do
      Runes::Security::ACL.new(agents: ["a"], extra_users: { "fleet-x" => [["publish", "runes/e"]] })
    end
    assert_match(/read\/write\/readwrite/, err.message)
  end

  private

  def setup_engine(world)
    hub = Runes::Transport::InProcess::Hub.new(name: "hardening-#{object_id}-#{Runes::Random.hex(4)}")
    transport = Runes::Transport::InProcess.new(hub: hub)
    transport.connect
    [nil, transport]
  end

  def assert_load_error(pattern, &block)
    err = assert_raises(Runes::Fleet::LoadError, &block)
    assert_match(pattern, err.message)
    err
  end
end
