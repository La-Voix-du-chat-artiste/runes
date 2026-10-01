# frozen_string_literal: true

require_relative "test_helper"

require "minitest/autorun"

require_relative "../lib/runes/fleet"
require_relative "../lib/runes/transport"
require_relative "../lib/runes/transport/in_process"

# Phase B of the Fleet DSL (docs/FLEET_DSL.md §5): rules as data, and the
# hermetic rule engine — declaration-order firing, restricted guards,
# next!, deterministic request ids through the RequestLedger (a
# redelivered event can never execute the same action twice), the
# max_actions_per_event budget with dead-letter, and the §10 refusal
# taxonomy. Everything runs on the in-process transport with synthetic
# events: no broker, no keys, no network.
class FleetRulesTest < Minitest::Test
  def fleet(src, args: {})
    Runes::Fleet.load(src, path: "(rules-test)", args: args)
  end

  def header
    "# fleet-spec: 0.1\n"
  end

  # A small but complete fleet: two channels, three roles on a route path,
  # one guarded rule chain, a presence rule, a guard_denied rule, a
  # schedule, and a dead_letter channel.
  def fleet_source(rules: nil, extra_channels: "")
    header + <<~'RUBY'
      fleet "mini" do
        transport :inproc
        channel :found,    "runes/events/found"
        channel :metrics,  "runes/events/metrics"
        channel :dead_letter, "runes/events/dead"
      RUBY
           .then { |s| s + extra_channels } +
      <<~'RUBY'
        agent :scraper do
          model "m"
          tools fs_read: :allow
        end
        agent :writer do
          model "m"
          tools fs_write: :allow
        end
        route :scraper, :writer
        fact :tone, "professional"
        schedule :weekly_report, cron: "0 9 * * MON"
      RUBY
           .then { |s| s + (rules || "") } +
      "end\n"
  end

  def basic_rules
    <<~'RUBY'
      on :found do |e|
        next! unless e.score > 0.7
        task :writer, "Redige pour %{name} (ton: %{tone})"
        publish :metrics, { kind: "qualified" }
      end
    RUBY
  end

  # ---- loading: rules are data, validated at load ----

  def test_rules_load_as_data_with_stable_ids
    world = fleet(fleet_source(rules: basic_rules))
    assert_equal 1, world.rules.size
    rule = world.rules.first
    assert_equal "found-0", rule.id
    assert_equal :channel, rule.source_kind
    assert_equal :found, rule.source
    assert_kind_of Proc, rule.block
    topo = world.topology
    assert_equal [{ "id" => "found-0", "source" => "channel:found", "line" => topo["rules"].first["line"] }], topo["rules"]
    assert_match(/\A[0-9a-f]{64}\z/, world.fingerprint)
  end

  def test_all_event_source_kinds_classify
    world = fleet(fleet_source(rules: <<~'RUBY'))
      on :agent_online do |e|
        notify "#{e.agent} is here", level: :info
      end
      on :mission_failed do |e|
        notify "mission down", level: :warn
      end
      on :guard_denied do |e|
        notify "refused", level: :warn
      end
      on :weekly_report do |e|
        notify "report time", level: :info
      end
    RUBY
    kinds = world.rules.map { |r| [r.source_kind, r.source] }
    assert_includes kinds, [:presence, :agent_online]
    assert_includes kinds, [:lifecycle, :mission_failed]
    assert_includes kinds, [:guard_denied, :guard_denied]
    assert_includes kinds, [:schedule, :weekly_report]
  end

  def test_unknown_source_is_a_load_error
    err = assert_raises(Runes::Fleet::LoadError) do
      fleet(fleet_source(rules: "on :nope do |e|\n  notify \"x\"\nend\n"))
    end
    assert_match(/unknown event source/, err.message)
  end

  def test_task_target_must_be_on_a_declared_route_edge
    assert_load_error(/not on a declared route edge/) do
      fleet(fleet_source(rules: "on :found do |e|\n  task :scraper, \"x\"\nend\n"))
    end
  end

  def test_task_to_unknown_role_is_a_load_error
    assert_load_error(/not on a declared route edge/) do
      fleet(fleet_source(rules: "on :found do |e|\n  task :ghost, \"x\"\nend\n"))
    end
  end

  def test_publish_to_undeclared_channel_is_a_load_error
    assert_load_error(/undeclared channel/) do
      fleet(fleet_source(rules: "on :found do |e|\n  publish :ghost, { k: 1 }\nend\n"))
    end
  end

  def test_notify_level_is_pinned
    assert_load_error(/notify level/) do
      fleet(fleet_source(rules: "on :found do |e|\n  notify \"x\", level: :loud\nend\n"))
    end
  end

  def test_guard_lambda_form_loads
    world = fleet(fleet_source(rules: <<~'RUBY'))
      on :found, guard: ->(e) { e.score > 0.7 && e.country == "FR" } do |e|
        task :writer, "go"
      end
    RUBY
    assert_kind_of Proc, world.rules.first.guard
  end

  def test_rule_shape_violations_are_load_errors
    assert_load_error(/needs a block/) { fleet(fleet_source(rules: "on :found\n")) }
    assert_load_error(/exactly \|e\|/) { fleet(fleet_source(rules: "on :found do |e, f|\n  notify \"x\"\nend\n")) }
    assert_load_error(/guard:.*lambda/) do
      fleet(fleet_source(rules: "on :found, guard: :nope do |e|\n  notify \"x\"\nend\n"))
    end
  end

  def test_rule_expressions_reject_escape_hatches
    %w[system send instance_eval eval].each do |bad|
      src = fleet_source(rules: "on :found do |e|\n  next! if e.#{bad}(\"ls\")\n  notify \"x\"\nend\n")
      assert_raises(Runes::Fleet::LoadError, "expected rejection of e.#{bad}") { fleet(src) }
    end
    # a lambda outside a rule is still world mode — still forbidden
    assert_raises(Runes::Fleet::LoadError) do
      fleet(fleet_source(rules: "fact :f, ->(e) { e }\n"))
    end
  end

  # ---- engine: hermetic run-time semantics (§5.3) ----

  def setup_engine(world, **opts)
    hub = Runes::Transport::InProcess::Hub.new(name: "fleet-rules-#{object_id}-#{Runes::Random.hex(4)}")
    transport = Runes::Transport::InProcess.new(hub: hub)
    transport.connect
    engine = Runes::Fleet::Engine.new(world, transport: transport, **opts)
    [engine, transport]
  end

  def test_channel_rule_fires_with_guard_next_and_templates
    world = fleet(fleet_source(rules: basic_rules))
    engine, transport = setup_engine(world)
    notices = []
    engine = Runes::Fleet::Engine.new(world, transport: transport, notifier: ->(n) { notices << n })
    engine.start

    tasks = []
    transport.subscribe("runes/agents/writer/tasks") { |m| tasks << Runes::Json.parse(m.payload) }
    metrics = []
    transport.subscribe("runes/events/metrics") { |m| metrics << Runes::Json.parse(m.payload) }

    low = Runes::Json.generate({ "score" => 0.2, "name" => "acme" })
    transport.publish("runes/events/found", low)
    assert_empty tasks, "guarded-out event must not fire"

    transport.publish("runes/events/found", Runes::Json.generate({ "score" => 0.9, "name" => "acme" }))
    assert_equal 1, tasks.size
    assert_equal "Redige pour acme (ton: professional)", tasks.first["prompt"]
    assert_match(/\A[0-9a-f]{16}\z/, tasks.first["request_id"])
    assert_equal [{ "kind" => "qualified" }], metrics
    assert_empty notices
  end

  def test_rules_fire_in_declaration_order_and_all_match
    world = fleet(fleet_source(rules: <<~'RUBY'))
      on :found do |e|
        publish :metrics, { order: 1 }
      end
      on :found do |e|
        publish :metrics, { order: 2 }
      end
    RUBY
    _engine, transport = setup_engine(world)
    engine = Runes::Fleet::Engine.new(world, transport: transport)
    engine.start
    seen = []
    transport.subscribe("runes/events/metrics") { |m| seen << Runes::Json.parse(m.payload)["order"] }

    transport.publish("runes/events/found", Runes::Json.generate({ "x" => 1 }))
    assert_equal [1, 2], seen, "all matching rules fire, in declaration order"
  end

  def test_redelivered_event_never_executes_the_same_action_twice
    world = fleet(fleet_source(rules: basic_rules))
    _e, transport = setup_engine(world)
    engine = Runes::Fleet::Engine.new(world, transport: transport)
    engine.start
    tasks = []
    transport.subscribe("runes/agents/writer/tasks") { |m| tasks << m }

    payload = Runes::Json.generate({ "score" => 0.9, "name" => "acme" })
    transport.publish("runes/events/found", payload)
    transport.publish("runes/events/found", payload) # redelivery, same event id

    assert_equal 1, tasks.size, "§5.3.3: the ledger dedupes the redelivered event"
  end

  def test_request_ids_are_deterministic_across_engines
    world = fleet(fleet_source(rules: basic_rules))
    e1, t1 = setup_engine(world)
    e2, t2 = setup_engine(world)
    e1.start
    e2.start
    got = [t1, t2].map do |transport|
      tasks = []
      transport.subscribe("runes/agents/writer/tasks") { |m| tasks << Runes::Json.parse(m.payload) }
      transport.publish("runes/events/found", Runes::Json.generate({ "score" => 0.9, "name" => "acme" }))
      tasks.first["request_id"]
    end
    assert_equal got.first, got.last, "§5.3.5: same fleet + same event ⇒ same ids"
  end

  def test_fanout_budget_fails_the_event_to_dead_letter
    rules = <<~'RUBY'
      on :found do |e|
        publish :metrics, { n: 1 }
      end
      on :found do |e|
        publish :metrics, { n: 2 }
      end
    RUBY
    world = fleet(fleet_source(rules: rules), args: { "max_actions_per_event" => 1 })
    _e, transport = setup_engine(world)
    engine = Runes::Fleet::Engine.new(world, transport: transport)
    engine.start
    dead = []
    transport.subscribe("runes/events/dead") { |m| dead << Runes::Json.parse(m.payload) }
    metrics = []
    transport.subscribe("runes/events/metrics") { |m| metrics << m }

    transport.publish("runes/events/found", Runes::Json.generate({ "x" => 1 }))

    assert_equal 1, metrics.size, "the action over budget never runs"
    assert_equal 1, dead.size
    assert_equal "fanout_exceeded", dead.first["event"]
    assert_equal 2, dead.first["count"]
  end

  def test_unparseable_payload_is_refused_and_dead_lettered
    world = fleet(fleet_source(rules: basic_rules))
    _e, transport = setup_engine(world)
    engine = Runes::Fleet::Engine.new(world, transport: transport)
    engine.start
    dead = []
    transport.subscribe("runes/events/dead") { |m| dead << Runes::Json.parse(m.payload) }
    fired = []
    transport.subscribe("runes/events/metrics") { |m| fired << m }

    transport.publish("runes/events/found", "this is not json")

    assert_empty fired
    assert_equal "schema_refused", dead.first["event"]
  end

  def test_guard_that_raises_is_a_refusal_event_not_a_skip
    world = fleet(fleet_source(rules: <<~'RUBY'))
      on :found do |e|
        next! if e.missing_field > 1
        publish :metrics, { fired: true }
      end
      on :found do |e|
        publish :metrics, { fired: "second-rule-still-runs" }
      end
    RUBY
    _e, transport = setup_engine(world)
    engine = Runes::Fleet::Engine.new(world, transport: transport)
    engine.start
    metrics = []
    transport.subscribe("runes/events/metrics") { |m| metrics << Runes::Json.parse(m.payload) }

    transport.publish("runes/events/found", Runes::Json.generate({ "x" => 1 }))

    assert_equal [{ "fired" => "second-rule-still-runs" }], metrics
    assert_equal 1, engine.journal.count { |j| j["kind"] == "rule_guard_error" }
  end

  def test_presence_and_guard_denied_sources
    world = fleet(fleet_source(rules: <<~'RUBY'))
      on :agent_online do |e|
        notify "online: #{e.agent}", level: :info
      end
      on :guard_denied do |e|
        notify "denied", level: :warn
      end
    RUBY
    _e, transport = setup_engine(world)
    notices = []
    engine = Runes::Fleet::Engine.new(world, transport: transport, notifier: ->(n) { notices << n })
    engine.start

    transport.publish("runes/agents/ada/status", "online")
    transport.publish("runes/guard/denied", Runes::Json.generate({ "tool" => "fs_write" }))

    assert_equal ["online: ada", "denied"], notices.map { |n| n["text"] }
    assert_equal %w[info warn], notices.map { |n| n["level"] }
  end

  def test_lifecycle_source_matches_event_name
    world = fleet(fleet_source(rules: <<~'RUBY'))
      on :mission_failed do |e|
        notify "mission #{e.mission} failed", level: :warn
      end
    RUBY
    _e, transport = setup_engine(world)
    notices = []
    engine = Runes::Fleet::Engine.new(world, transport: transport, notifier: ->(n) { notices << n })
    engine.start

    other = Runes::Json.generate({ "event" => "conversation", "text" => "hi" })
    transport.publish("runes/prompts/abc/progress", other)
    assert_empty notices

    failed = Runes::Json.generate({ "event" => "mission_failed", "mission" => "m-1" })
    transport.publish("runes/prompts/abc/progress", failed)
    assert_equal ["mission m-1 failed"], notices.map { |n| n["text"] }
  end

  def test_schedule_tick_fires_only_when_cron_matches
    world = fleet(fleet_source(rules: <<~'RUBY'))
      on :weekly_report do |e|
        notify "report", level: :info
      end
    RUBY
    _e, transport = setup_engine(world)
    notices = []
    engine = Runes::Fleet::Engine.new(world, transport: transport, notifier: ->(n) { notices << n })
    engine.start

    monday_nine = Time.utc(2026, 10, 5, 9, 0) # a Monday
    tuesday_nine = Time.utc(2026, 10, 6, 9, 0)

    engine.tick(tuesday_nine)
    assert_empty notices
    engine.tick(monday_nine)
    assert_equal ["report"], notices.map { |n| n["text"] }
  end

  def test_runtime_refuses_actions_the_load_time_probe_could_not_see
    world = fleet(fleet_source(rules: basic_rules))
    # A hand-built rogue rule smuggled in after load: the engine's
    # fail-closed action gate is the last line of defence (§10 GuardError).
    rogue = Runes::Fleet::Rule.new(
      id: "rogue-9", source_kind: :channel, source: :found,
      guard: nil, block: proc { |e| task :ghost, "x" }, line: 0
    )
    world.rules << rogue

    _e, transport = setup_engine(world)
    engine = Runes::Fleet::Engine.new(world, transport: transport)
    engine.start

    transport.publish("runes/events/found", Runes::Json.generate({ "score" => 0.9, "name" => "acme" }))

    assert_equal 1, engine.journal.count { |j| j["kind"] == "guard_refused" }
  end

  def test_notify_interpolates_event_fields_and_facts
    world = fleet(fleet_source(rules: <<~'RUBY'))
      on :found do |e|
        notify "contact %{name} (tone: %{tone})", level: :info
      end
    RUBY
    _e, transport = setup_engine(world)
    notices = []
    engine = Runes::Fleet::Engine.new(world, transport: transport, notifier: ->(n) { notices << n })
    engine.start

    transport.publish("runes/events/found", Runes::Json.generate({ "name" => "acme" }))
    assert_equal ["contact acme (tone: professional)"], notices.map { |n| n["text"] }
  end

  private

  def assert_load_error(pattern, &block)
    err = assert_raises(Runes::Fleet::LoadError, &block)
    assert_match(pattern, err.message)
    err
  end
end
