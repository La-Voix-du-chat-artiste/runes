# frozen_string_literal: true

require_relative "test_helper"

require "minitest/autorun"
require "tmpdir"
require "json"

require_relative "../lib/runes"
# bin/runes-acl is a shebang script (no .rb), and its CLI bottom is guarded
# by a $PROGRAM_NAME comparison — `load` is safe and keeps tests on the
# real renderer, per the file's own design note.
load File.expand_path("../bin/runes-acl", __dir__)

# Phase C of the Fleet DSL (docs/FLEET_DSL.md §8/§11): L2 conformance —
# the static-analysis extracts are golden-file diffed in the suite, the
# ACL extract round-trips through the real bin/runes-acl renderer (no
# catch-all allow, fleet roles = broker usernames, fail closed both
# ways), the engine records its determinism fingerprint at boot, and the
# Runner persists the journal as JSON Lines a human can tail.
class FleetConformanceTest < Minitest::Test
  # The example fleet is the single source of truth: the suite tests it,
  # and operators can run it (`runes-daemon --fleet examples/prospection.fleet.rb`).
  FIXTURE = File.expand_path("../examples/prospection.fleet.rb", __dir__)
  GOLDEN = File.expand_path("fixtures/fleet/prospection.golden.json", __dir__)

  def world
    @world ||= Runes::Fleet.load_file(FIXTURE)
  end

  # ---- L2: golden extracts (§8) ----

  def test_extracts_match_the_golden_file
    golden = JSON.parse(File.read(GOLDEN))
    assert_equal golden["fleet"], world.name
    assert_equal golden["fingerprint"], world.fingerprint,
                 "extracts drifted — regenerate the golden file intentionally (see its _comment)"
    assert_equal golden["policy_extract"], world.policy_extract
    assert_equal golden["acl_extract"], world.acl_extract
    assert_equal golden["topology"], world.topology
  end

  def test_topology_lists_rules_in_declaration_order
    rules = world.topology["rules"]
    assert_equal %w[contact_found-0 contact_qualified-1 draft_ready-2 guard_denied-3 weekly_report-4],
                 rules.map { |r| r["id"] }
    assert_equal "channel:contact_found", rules.first["source"]
    assert_kind_of Integer, rules.first["line"]
  end

  # ---- §8.4: the determinism certificate is recorded at boot ----

  def test_engine_boot_record_carries_the_fingerprint
    engine, = engine_with_hub
    engine.start
    boot = engine.journal.first
    assert_equal "fleet_boot", boot["kind"]
    assert_equal world.name, boot["fleet"]
    assert_equal world.fingerprint, boot["fingerprint"]
    assert_match(/\A\d{4}-\d{2}-\d{2}T/, boot["at"])
  end

  # ---- §8.2: the ACL extract round-trips through bin/runes-acl ----

  def test_acl_round_trip_merges_fleet_grants_without_catch_all
    acl = Runes::Security::ACL.new(
      agents: world.roles.keys.map(&:to_s),
      fleet_grants: world.acl_extract,
      fleet_note: "prospection (test)"
    )
    rendered = acl.render

    # route-edge delta landed in the right user's section
    section = rendered.split(/^user /).find { |s| s.start_with?("scraper\n") }
    assert_includes section, "topic write runes/agents/writer/tasks"
    writer = rendered.split(/^user /).find { |s| s.start_with?("writer\n") }
    assert_includes writer, "topic read runes/agents/writer/tasks"
    # agent → channel edge
    assert_includes section, "topic write runes/events/metrics"
    # the reviewer never gains write to the writer's task topic
    reviewer = rendered.split(/^user /).find { |s| s.start_with?("reviewer\n") }
    refute_includes reviewer, "topic write runes/agents/writer/tasks"
    # no catch-all allow anywhere — the file only narrows, never widens
    refute_match(/^topic (read|write|readwrite) #\r?$/, rendered)
    assert_includes rendered, "#   fleet:        prospection (test)"
  end

  def test_acl_fails_closed_when_fleet_role_is_not_an_agent
    err = assert_raises(Runes::Security::ACL::ACLError) do
      Runes::Security::ACL.new(agents: ["scraper"], fleet_grants: { "writer" => [["write", "runes/agents/writer/tasks"]] })
    end
    assert_match(/not .*agent ids/, err.message)
  end

  def test_acl_fails_closed_on_bad_fleet_access
    err = assert_raises(Runes::Security::ACL::ACLError) do
      Runes::Security::ACL.new(
        agents: ["scraper"],
        fleet_grants: { "scraper" => [["publish", "runes/events/metrics"]] }
      )
    end
    assert_match(/read\/write\/readwrite/, err.message)
  end

  # ---- Runner: journal persistence (the daemon wiring) ----

  def test_runner_persists_jsonl_journal_with_boot_first
    Dir.mktmpdir do |dir|
      path = File.join(dir, "fleet-journal.jsonl")
      runner, transport = runner_with_hub(journal_path: path, tick_every: 60)
      runner.start

      transport.publish("runes/events/contacts/qualified", Runes::Json.generate({ "score" => 0.9, "name" => "acme" }))
      runner.stop

      lines = File.readlines(path, chomp: true).map { |l| JSON.parse(l) }
      assert_equal "fleet_boot", lines.first["kind"]
      assert_equal world.fingerprint, lines.first["fingerprint"]
      assert lines.any? { |l| l["kind"] == "action" && l.dig("action", "kind") == "task" },
             "expected a journaled task action, got: #{lines.inspect}"
      # every entry is one of the known kinds — the journal schema is stable
      assert lines.all? { |l| %w[fleet_boot action rule_guard_error guard_refused action_failed fanout_exceeded].include?(l["kind"]) }
    end
  end

  def test_runner_timer_thread_fires_schedules
    Dir.mktmpdir do |dir|
      path = File.join(dir, "j.jsonl")
      # Pin the clock to a Monday 09:00 so the fixture's weekly cron matches.
      monday_nine = -> { Time.utc(2026, 10, 5, 9, 0) }
      runner, = runner_with_hub(journal_path: path, tick_every: 0.05, now: monday_nine)
      runner.start
      deadline = Time.now + 3
      sleep 0.1 until File.exist?(path) && File.readlines(path).grep(/"action"/).any? || Time.now > deadline
      runner.stop

      assert File.readlines(path).grep(/"action"/).any?, "timer thread should have fired the weekly_report rule within 3s"
    end
  end

  def test_runner_stop_is_idempotent_and_engine_stops
    runner, = runner_with_hub
    runner.start
    assert runner.running?
    runner.stop
    refute runner.running?
    refute runner.engine.started?
    runner.stop # second stop is a no-op, not an error
  end

  private

  def hub
    @hub ||= Runes::Transport::InProcess::Hub.new(name: "fleet-conf-#{object_id}-#{Runes::Random.hex(4)}")
  end

  def engine_with_hub
    transport = Runes::Transport::InProcess.new(hub: hub)
    transport.connect
    [Runes::Fleet::Engine.new(world, transport: transport), transport]
  end

  def runner_with_hub(journal_path: nil, tick_every: 1.0, now: nil)
    transport = Runes::Transport::InProcess.new(hub: hub)
    transport.connect
    runner = Runes::Fleet::Runner.new(
      world, transport: transport, journal_path: journal_path, tick_every: tick_every,
      now: now
    )
    [runner, transport]
  end
end
