# frozen_string_literal: true

require_relative "test_helper"

require "minitest/autorun"
require "tmpdir"

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

  # ---- §5.3.2: a raise refuses the WHOLE rule, never half-executes it ----

  def test_rule_body_raise_discards_actions_recorded_before_the_raise
    world = fleet(header + <<~'RUBY')
      fleet "raise-discard" do
        transport :inproc
        group "raise-g"
        channel :events, "runes/raise/events"
        channel :metrics, "runes/raise/metrics"
        agent :src do
          model "m"
          tools :none
        end
        agent :sink do
          model "m"
          tools :none
        end
        route :src, :sink
        on :events do |e|
          task :sink, "recorded before the raise"
          publish :metrics, { v: e.nope }   # NoMethodError at run time (probe event synthesizes the field)
        end
        on :events do |e|
          publish :metrics, { second: true }
        end
      end
    RUBY
    _e, transport = setup_engine(world)
    engine = Runes::Fleet::Engine.new(world, transport: transport)
    engine.start
    tasks = []
    metrics = []
    transport.subscribe("runes/agents/sink/tasks") { |m| tasks << m }
    transport.subscribe("runes/raise/metrics") { |m| metrics << Runes::Json.parse(m.payload) }

    transport.publish("runes/raise/events", Runes::Json.generate({ "email" => "a@b.c" }))

    assert_empty tasks, "a refused rule's actions must not execute — not even those recorded before the raise"
    assert_equal [{ "second" => true }], metrics, "the other rule for the same event still fires (all-match)"
    assert_equal 1, engine.journal.count { |j| j["kind"] == "rule_guard_error" }
    assert_equal 1, engine.journal.count { |j| j["kind"] == "action" }
  end

  # ---- §8.4: the boot record is first even against retained replays ----

  def test_boot_record_commits_before_retained_replays
    world = fleet(world_source)
    _e, transport = setup_engine(world)
    # In-process transports deliver retained messages synchronously DURING
    # subscribe — without the ordering fix this replay lands before boot.
    transport.publish("runes/events/hardened",
                      Runes::Json.generate({ "email" => "r@x.fr" }), retain: true)
    engine = Runes::Fleet::Engine.new(world, transport: transport)
    engine.start

    assert_equal "fleet_boot", engine.journal.first["kind"],
                 "the boot record must precede even retained replays"
    assert engine.journal.any? { |j| j["kind"] == "action" }, "the retained replay still fired its rule"
  end

  # ---- Runner: tick_every 0 hosts no timer (no busy spin) ----

  def test_runner_with_tick_every_zero_hosts_no_timer
    Dir.mktmpdir do |dir|
      path = File.join(dir, "j.jsonl")
      world = fleet(header + <<~'RUBY')
        fleet "notimer" do
          transport :inproc
          channel :out, "runes/notimer/out"
          schedule :heartbeat, cron: "0 9 * * MON"
          on :heartbeat do |e|
            publish :out, { beat: true }
          end
        end
      RUBY
      hub = Runes::Transport::InProcess::Hub.new(name: "hardening-#{object_id}-#{Runes::Random.hex(4)}")
      transport = Runes::Transport::InProcess.new(hub: hub)
      transport.connect
      # Pinned to Monday 09:00 so the cron WOULD match on every tick.
      monday_nine = -> { Time.utc(2026, 10, 5, 9, 0) }
      runner = Runes::Fleet::Runner.new(
        world, transport: transport, journal_path: path, tick_every: 0, now: monday_nine
      )
      runner.start
      assert runner.running?
      runner.stop

      lines = File.readlines(path, chomp: true).map { |l| Runes::Json.parse(l) }
      assert_equal ["fleet_boot"], lines.map { |l| l["kind"] },
                   "tick_every 0 must not run the timer thread — a sleep-0 loop would spin a core"

      runner.start
      runner.tick(monday_nine.call) # manual delegation still fires schedules
      runner.stop
      lines = File.readlines(path, chomp: true).map { |l| Runes::Json.parse(l) }
      assert lines.any? { |l| l["kind"] == "action" }, "manual tick still fires schedules"
    end
  end

  # ---- presence under N runners: exactly once fleet-wide, boundary lossy ----

  def test_presence_notifications_fire_exactly_once_fleet_wide
    world = fleet(header + <<~'RUBY')
      fleet "presence-fleet" do
        transport :inproc
        group "presence-g"
        agent :watcher do
          model "m"
          tools :none
        end
        on :agent_online do |e|
          notify "up: #{e.agent}", level: :info
        end
        on :agent_offline do |e|
          notify "down: #{e.agent}", level: :warn
        end
      end
    RUBY
    hub = Runes::Transport::InProcess::Hub.new(name: "hardening-#{object_id}-#{Runes::Random.hex(4)}")
    t1 = Runes::Transport::InProcess.new(hub: hub)
    t2 = Runes::Transport::InProcess.new(hub: hub)
    t1.connect
    t2.connect
    e1 = Runes::Fleet::Engine.new(world, transport: t1)
    e2 = Runes::Fleet::Engine.new(world, transport: t2)
    n1 = []
    n2 = []
    e1.instance_variable_set(:@notifier, ->(n) { n1 << n["text"] })
    e2.instance_variable_set(:@notifier, ->(n) { n2 << n["text"] })
    e1.start
    e2.start

    # The full sequence has five true transitions (up down up down up). The
    # shared group round-robins updates across runners; the §5.2 caveat says
    # a boundary transition is attributed to the runner that saw the change
    # — so exactly four notifications fleet-wide, never a duplicate.
    %w[online offline online online offline online].each do |s|
      t1.publish("runes/agents/ada/status", s)
    end

    assert_equal 4, n1.size + n2.size, "no status update may notify twice fleet-wide"
    assert_equal n1.uniq, n1, "no duplicate transitions within a runner"
    assert_equal n2.uniq, n2, "no duplicate transitions within a runner"
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
