# frozen_string_literal: true

require_relative "test_helper"

require "minitest/autorun"

require_relative "../lib/runes/fleet"

# Phase A of the Fleet DSL (docs/FLEET_DSL.md): the restricted-subset Prism
# walker plus the world-declaration loader — L1 conformance for the world
# half of the spec. Rules (§5), the lowering onto runes (§9) and the
# run-time wiring land in the next phase; this suite proves the load is
# fail-closed (P3), atomic (§10) and produces the §8 static-analysis
# extracts deterministically.
class FleetLoaderTest < Minitest::Test
  FIXTURE = File.expand_path("../examples/prospection.fleet.rb", __dir__)

  def world
    @world ||= Runes::Fleet.load_file(FIXTURE)
  end

  # ---- the happy path: the spec's §12 world, as a real file ----

  def test_loads_the_spec_example_world
    w = world
    assert_equal "prospection", w.name
    assert_equal "CRM pipeline: qualify contacts, draft outreach, review.", w.description
    assert_equal :mqtt5, w.transport
    assert_equal "prospection-prompts", w.group
  end

  def test_roles_with_default_deny_tools
    assert_equal %i[scraper writer reviewer], world.roles.keys

    scraper = world.roles[:scraper]
    assert_equal "deepseek-flash", scraper.model
    assert_equal({ variation: :high }, scraper.model_opts)
    assert_equal({ fs_read: :allow, exec: { allow: %w[curl jq] } }, scraper.tools)
    assert_equal "workspace/scraper", scraper.workspace
    assert_equal "config/keys/scraper.pem", scraper.identity
    assert_equal 2, scraper.concurrency

    assert_equal({ fs_write: :allow }, world.roles[:writer].tools)
    # `tools :none` is the explicit empty set, normalized to {}
    assert_equal({}, world.roles[:reviewer].tools)
  end

  def test_channels_bind_names_to_topics
    assert_equal "runes/events/contacts/qualified", world.channels[:contact_qualified].topic
    assert_equal :contact, world.channels[:contact_qualified].schema
    assert_equal true, world.channels[:outbox] && !world.channels[:metrics].retain
  end

  def test_routes_are_directed_edges
    edges = world.edges
    assert_includes edges, Runes::Fleet::World::Edge.new(from: :scraper, to: :writer, when: nil)
    assert_includes edges, Runes::Fleet::World::Edge.new(from: :writer, to: :reviewer, when: nil)
    assert_includes edges, Runes::Fleet::World::Edge.new(from: :reviewer, to: :outbox, when: :accepted)
    # keyword spelling, one edge per pair
    assert_includes edges, Runes::Fleet::World::Edge.new(from: :scraper, to: :metrics, when: nil)
  end

  def test_facts_and_schedules
    assert_equal 20, world.facts[:max_drafts_per_hour].value
    assert_equal "professional", world.facts[:outreach_tone].value
    assert_equal "0 9 * * MON", world.schedules[:weekly_report].cron
  end

  def test_config_precedence_defaults_below_file_below_args
    assert_equal "staging", world.config["env"] # file overrides the default
    assert_equal 16, world.config["max_actions_per_event"] # built-in default
    overridden = Runes::Fleet.load_file(FIXTURE, args: { env: "production" })
    assert_equal "production", overridden.config["env"]
  end

  # ---- §8 static-analysis outputs ----

  def test_policy_extract_merges_every_tools_clause
    extract = world.policy_extract
    assert_equal false, extract["default_allow"]
    assert_equal(
      { "fs_read" => "allow", "exec" => { "allow" => %w[curl jq] } },
      extract["roles"]["scraper"]["tools"]
    )
    assert_equal({ "fs_write" => "allow" }, extract["roles"]["writer"]["tools"])
    assert_equal({}, extract["roles"]["reviewer"]["tools"])
  end

  def test_acl_extract_derives_route_edges_and_nothing_more
    extract = world.acl_extract
    # edge :scraper → :writer authorizes exactly the addressed-task topic
    assert_includes extract["scraper"], ["write", "runes/agents/writer/tasks"]
    assert_includes extract["writer"], ["read", "runes/agents/writer/tasks"]
    # agent → channel edge authorizes publishing on the channel topic
    assert_includes extract["scraper"], ["write", "runes/events/metrics"]
    # no catch-all, no grants for unrelated roles
    refute_includes extract["reviewer"], ["write", "runes/agents/writer/tasks"]
    assert_nil extract["reviewer"].find { |(_, topic)| topic == "#" }
  end

  def test_topology_shape_is_stable_for_the_observatory
    topo = world.topology
    assert_equal "prospection", topo["name"]
    assert_equal %w[scraper writer reviewer], topo["agents"]
    assert_equal({ "from" => "scraper", "to" => "writer", "when" => nil }, topo["edges"].first)
    assert_equal "runes/events/metrics", topo["channels"]["metrics"]
    # rules are listed in declaration order (§5.3.1 is part of the shape)
    assert_equal %w[contact_found-0 contact_qualified-1 draft_ready-2 guard_denied-3 weekly_report-4],
                 topo["rules"].map { |r| r["id"] }
  end

  def test_fingerprint_is_deterministic
    again = Runes::Fleet.load_file(FIXTURE)
    assert_equal world.fingerprint, again.fingerprint
    assert_match(/\A[0-9a-f]{64}\z/, world.fingerprint)
  end

  # ---- fail-closed loading (P3 / §10) ----

  def test_syntax_error_aborts_with_line_number
    err = assert_raises(Runes::Fleet::LoadError) do
      Runes::Fleet.load(header + "fleet \"x\" do\n  agent :a do\n    tools :\n  end\nend\n")
    end
    assert_match(/syntax error/, err.message)
  end

  FORBIDDEN = {
    "eval(\"puts 1\")" => /forbidden construct|unknown construct.*eval|eval.*forbidden/,
    "system(\"ls\")" => /system/,
    "`id`" => /XStringNode/,
    "require \"json\"" => /require/,
    "send(:puts, \"x\")" => /send/,
    "instance_eval(\"1\")" => /instance_eval/,
    '"interp #{1 + 1}"' => /InterpolatedStringNode/,
    "$global = 1" => /GlobalVariableWriteNode/,
    "JSON" => /ConstantReadNode/,
    "class Foo; end" => /ClassNode/,
    "def m; end" => /DefNode/,
    "a.b" => /receivers are forbidden/,
    "tools :none if true" => /IfNode/,
    "while true; end" => /WhileNode/,
    "lambda { }" => /lambda/,
    "Thread.new { }" => /ConstantReadNode|forbidden/
  }.freeze

  def test_walker_rejects_forbidden_constructs
    FORBIDDEN.each do |stmt, pattern|
      src = header + <<~RUBY
        fleet "x" do
          agent :a do
            #{stmt}
          end
        end
      RUBY
      err = assert_raises(Runes::Fleet::LoadError, "expected rejection of: #{stmt}") do
        Runes::Fleet.load(src)
      end
      assert_match(pattern, err.message, "message for: #{stmt}")
      assert_match(/line \d+/, err.message)
    end
  end

  def test_unknown_declaration_is_a_load_error_not_nomethoderror
    err = assert_raises(Runes::Fleet::LoadError) do
      Runes::Fleet.load(header + "fleet \"x\" do\n  frobnicate :a\nend\n")
    end
    assert_match(/frobnicate/, err.message)
  end

  def test_misplaced_declaration_is_rejected
    err = assert_raises(Runes::Fleet::LoadError) do
      Runes::Fleet.load(header + "model \"x\"\n")
    end
    assert_match(/unknown top-level declaration/, err.message)
  end

  def test_duplicate_agent_id_aborts
    assert_load_error(/duplicate agent/) do
      Runes::Fleet.load(header + <<~RUBY)
        fleet "x" do
          transport :inproc
          agent :a do
            tools :none
          end
          agent :a do
            tools :none
          end
        end
      RUBY
    end
  end

  def test_missing_tools_clause_fails_loudly
    assert_load_error(/default-deny is loud/) do
      Runes::Fleet.load(header + <<~RUBY)
        fleet "x" do
          transport :inproc
          agent :a do
            model "m"
          end
        end
      RUBY
    end
  end

  def test_route_to_unknown_endpoint_aborts
    assert_load_error(/route target/) do
      Runes::Fleet.load(header + <<~RUBY)
        fleet "x" do
          transport :inproc
          agent :a do
            tools :none
          end
          route :a, :ghost
        end
      RUBY
    end
  end

  def test_channel_topic_must_stay_in_the_runes_org
    assert_load_error(/fail closed|must match/) do
      Runes::Fleet.load(header + <<~RUBY)
        fleet "x" do
          transport :inproc
          channel :evil, "other-org/events"
        end
      RUBY
    end
  end

  def test_duplicate_channel_topic_aborts
    assert_load_error(/already bound/) do
      Runes::Fleet.load(header + <<~RUBY)
        fleet "x" do
          transport :inproc
          channel :one, "runes/events/e"
          channel :two, "runes/events/e"
        end
      RUBY
    end
  end

  def test_reserved_keywords_fail_with_precise_errors
    assert_load_error(/reserved.*v0.2/) do
      Runes::Fleet.load(header + <<~RUBY)
        fleet "x" do
          transport :inproc
          cell :budget, 100
        end
      RUBY
    end
    assert_load_error(/reserved.*cron/) do
      Runes::Fleet.load(header + <<~RUBY)
        fleet "x" do
          transport :inproc
          schedule :s, interval: 300
        end
      RUBY
    end
  end

  def test_header_is_enforced
    err = assert_raises(Runes::Fleet::LoadError) do
      Runes::Fleet.load("fleet \"x\" do\n  transport :inproc\nend\n")
    end
    assert_match(/fleet-spec/, err.message)

    err = assert_raises(Runes::Fleet::LoadError) do
      Runes::Fleet.load("# fleet-spec: 9.9\nfleet \"x\" do\n  transport :inproc\nend\n")
    end
    assert_match(/unsupported fleet-spec 9.9/, err.message)
  end

  def test_transport_is_required
    assert_load_error(/transport is required/) do
      Runes::Fleet.load(header + "fleet \"x\" do\nend\n")
    end
  end

  def test_exactly_one_fleet_block
    assert_load_error(/exactly one fleet/) do
      Runes::Fleet.load(header + "fleet \"a\" do\n  transport :inproc\nend\nfleet \"b\" do\n  transport :inproc\nend\n")
    end
  end

  def test_bad_cron_shape_aborts
    assert_load_error(/5-field cron/) do
      Runes::Fleet.load(header + <<~RUBY)
        fleet "x" do
          transport :inproc
          schedule :s, cron: "every monday"
        end
      RUBY
    end
  end

  def test_block_parameters_are_reserved_for_rules
    err = assert_raises(Runes::Fleet::LoadError) do
      Runes::Fleet.load(header + "fleet \"x\" do |f|\n  transport :inproc\nend\n")
    end
    assert_match(/reserved for rules/, err.message)
  end

  def test_agent_ids_are_acl_safe
    assert_load_error(/invalid agent id/) do
      Runes::Fleet.load(header + <<~RUBY)
        fleet "x" do
          transport :inproc
          agent :"a/bad" do
            tools :none
          end
        end
      RUBY
    end
  end

  # A failed load raises LoadError and nothing partial escapes: the API
  # returns no world at all, so there is no half-built state to leak
  # subscriptions or grants from (§10 atomicity).
  def test_failed_load_exposes_no_partial_world
    result = Runes::Fleet.load(header + "fleet \"x\" do\n  transport :inproc\n  cell :c, 1\nend\n")
    flunk "reserved keyword must not load"
  rescue Runes::Fleet::LoadError
    pass
  end

  private

  def header
    "# fleet-spec: 0.1\n"
  end

  def assert_load_error(pattern, &block)
    err = assert_raises(Runes::Fleet::LoadError, &block)
    assert_match(pattern, err.message)
    err
  end
end
