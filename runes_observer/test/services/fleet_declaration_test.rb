require "test_helper"

# The declared half of the topology page (docs/FLEET_DSL.md §8, observer
# side): a .fleet.rb loaded through the harness's own loader, presented as
# plain structs and reconciled against the observed graph. Feature is off
# (test_helper sets RUNES_OBSERVER_FLEET=off); every test here builds its
# own fleet file in a tmpdir and restores the knob.
class FleetDeclarationTest < ActiveSupport::TestCase
  FLEET = <<~'RUBY'
    # fleet-spec: 0.1
    fleet "declared" do
      transport :inproc
      group "declared-g"
      channel :events, "runes/declared/events"
      channel :dead_letter, "runes/declared/dead"
      agent :lead do
        model "m1"
        tools fs_read: :allow
      end
      agent :worker do
        model "m2"
        tools :none
      end
      route :lead, :worker
      on :events do |e|
        task :worker, "go"
      end
    end
  RUBY

  setup do
    @dir = Dir.mktmpdir("runes-fleet-decl-")
    @path = File.join(@dir, "declared.fleet.rb")
    File.write(@path, FLEET)
    @old = ENV["RUNES_OBSERVER_FLEET"]
    ENV["RUNES_OBSERVER_FLEET"] = @path
    FleetDeclaration.reset_cache!
  end

  teardown do
    ENV["RUNES_OBSERVER_FLEET"] = @old
    FleetDeclaration.reset_cache!
    FileUtils.remove_entry(@dir) if @dir && Dir.exist?(@dir)
  end

  def node(id)
    FleetTopology::Node.new(agent_id: id, state: "online", display_state: "online",
                            packets: 1, tools: 1, inbound: 1, outbound: 0,
                            executed: 0, errors: 0)
  end

  def edge(from, to)
    FleetTopology::Edge.new(from: from, to: to, tasks: 2, replies: 1, errors: 0,
                            avg_ms: 5.0, max_ms: 9.0, last_at: Time.current)
  end

  test "path follows the explicit environment variable" do
    assert_equal @path, FleetDeclaration.path
    ENV["RUNES_OBSERVER_FLEET"] = "off"
    assert_nil FleetDeclaration.path, "`off` disables the feature"
  end

  test "overview presents the loaded world's extracts" do
    overview = FleetDeclaration.overview

    assert_equal "declared", overview.name
    assert_equal 64, overview.fingerprint.length, "the §8.4 determinism fingerprint"
    assert_equal "inproc", overview.transport
    assert_equal "declared-g", overview.group
    assert_equal "fleet-declared", overview.runtime_user
    assert_equal @path, overview.path
    assert_equal %w[lead worker], overview.roles.map(&:id)
    assert_equal "fs_read", overview.roles.first.tools
    assert_equal "none", overview.roles.last.tools
    assert_equal %w[runes/declared/events runes/declared/dead], overview.channels.map(&:topic)
    assert_equal [%w[lead worker]], overview.edges.map { |e| [e.from, e.to] }
    assert_equal ["channel:events"], overview.rules.map(&:source)
    assert_kind_of Integer, overview.rules.first.line
  end

  test "a fleet file that fails to load renders as an error, never a raise" do
    File.write(@path, "# fleet-spec: 0.1\nfleet \"x\" do\n  transport :inproc\n  spawn :a\nend\n")

    assert_nil FleetDeclaration.overview
    assert_match(/reserved/, FleetDeclaration.error,
                 "the refusal reason reaches the page")
  end

  test "an explicitly named file that does not exist is an error, not silence" do
    ENV["RUNES_OBSERVER_FLEET"] = File.join(@dir, "nope.fleet.rb")

    assert_nil FleetDeclaration.overview
    assert_match(/no such file/i, FleetDeclaration.error)
  end

  test "editing the file is visible on the next request" do
    assert_equal "declared", FleetDeclaration.overview.name

    File.write(@path, FLEET.sub('"declared"', '"renamed"'))
    File.utime(Time.now + 5, Time.now + 5, @path) # guarantee a new mtime

    assert_equal "renamed", FleetDeclaration.overview.name
  end

  test "drift separates silent declarations from undeclared observations" do
    # lead and worker declared AND observed; stranger and the reverse link
    # observed but never declared.
    drift = FleetDeclaration.drift(
      [node("lead"), node("worker"), node("stranger")],
      [edge("lead", "worker"), edge("worker", "lead")]
    )

    assert_empty drift.roles_silent
    assert_equal %w[stranger], drift.agents_undeclared
    assert_empty drift.edges_silent
    assert_equal [%w[worker lead]], drift.edges_undeclared
    refute drift.quiet?
  end

  test "drift with nothing observed reports the whole declaration as silent" do
    drift = FleetDeclaration.drift([], [])

    assert_equal %w[lead worker], drift.roles_silent
    assert_empty drift.agents_undeclared
    assert_equal [%w[lead worker]], drift.edges_silent
    assert_empty drift.edges_undeclared
    refute drift.quiet?
  end

  test "drift is nil when the feature is off" do
    ENV["RUNES_OBSERVER_FLEET"] = "off"

    assert_nil FleetDeclaration.drift([], [])
  end
end
