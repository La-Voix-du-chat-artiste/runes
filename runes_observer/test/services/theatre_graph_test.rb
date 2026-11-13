require "test_helper"
require "tmpdir"

# Workspace slice 2D: the theatre graph merges the observed fleet
# (FleetTopology over recent packets) with the declared fleet (dashed).
class TheatreGraphTest < ActiveSupport::TestCase
  FLEET = <<~'RUBY'
    # fleet-spec: 0.1
    fleet "declared" do
      transport :inproc
      group "declared-g"
      agent :lead do
        model "m1"
        tools :none
      end
      agent :worker do
        model "m2"
        tools :none
      end
      agent :ghost do
        model "m3"
        tools :none
      end
      route :lead, :worker
    end
  RUBY

  setup do
    @dir = Dir.mktmpdir("runes-theatre-")
    @path = File.join(@dir, "declared.fleet.rb")
    File.write(@path, FLEET)
    @old_fleet = ENV["RUNES_OBSERVER_FLEET"]
    ENV["RUNES_OBSERVER_FLEET"] = @path
    FleetDeclaration.reset_cache!
  end

  teardown do
    ENV["RUNES_OBSERVER_FLEET"] = @old_fleet
    FleetDeclaration.reset_cache!
    FileUtils.remove_entry(@dir)
  end

  test "nodes carry positions and the observed agents appear" do
    graph = Theatre::Graph.new.to_h

    ids = graph[:nodes].map { |n| n[:id] }
    assert_includes ids, "runes-alpha"
    assert_includes ids, "runes-beta"
    node = graph[:nodes].find { |n| n[:id] == "runes-alpha" }
    assert node[:x].is_a?(Float) || node[:x].is_a?(Integer)
    assert node[:r] >= FleetTopology::Layout::NODE_MIN
  end

  test "declared roles merge in: observed ones flagged declared, silent ones dashed nodes" do
    # runes-alpha is not a declared role; lead/worker are declared but
    # unobserved, ghost too.
    graph = Theatre::Graph.new.to_h

    lead = graph[:nodes].find { |n| n[:id] == "lead" }
    assert_not_nil lead
    assert_equal "silent", lead[:state]
    assert lead[:declared]

    edge = graph[:edges].find { |e| e[:from] == "lead" && e[:to] == "worker" }
    assert_not_nil edge
    assert edge[:declared], "a declared-but-unobserved route renders dashed"
    assert_equal 0, edge[:tasks]
  end

  test "an observed delegation becomes a non-declared edge with geometry" do
    Packet.create!(
      topic: "runes/agents/runes-beta/tasks/req-9", kind: "task", request_id: "req-9",
      agent_id: "runes-beta",
      payload: JSON.generate("request_id" => "req-9", "from" => "runes-alpha", "prompt" => "do it"),
      payload_bytes: 60, occurred_at: 1.minute.ago, received_at: 1.minute.ago
    )

    graph = Theatre::Graph.new.to_h
    edge = graph[:edges].find { |e| e[:from] == "runes-alpha" && e[:to] == "runes-beta" }

    assert_not_nil edge
    assert_not edge[:declared]
    assert_equal 1, edge[:tasks]
    assert edge[:x1] && edge[:y1] && edge[:x2] && edge[:y2] && edge[:cx] && edge[:cy]
  end

  test "the window is reported" do
    assert_equal 30, Theatre::Graph.new.to_h[:window_minutes]
  end

  test "without a declaration the graph is purely observed" do
    ENV["RUNES_OBSERVER_FLEET"] = "off"
    FleetDeclaration.reset_cache!

    graph = Theatre::Graph.new.to_h
    assert graph[:nodes].all? { |n| !n[:declared] }
    assert graph[:edges].all? { |e| !e[:declared] }
  end
end
