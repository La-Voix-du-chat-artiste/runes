require "test_helper"

# The graph is only worth drawing if the derivation is honest: an edge must
# come from a packet that actually states both ends, and a task whose sender is
# unknown must show up as inbound work rather than a fabricated arrow.
class FleetTopologyTest < ActiveSupport::TestCase
  setup do
    Packet.delete_all
    Agent.delete_all
  end

  def agent(id, state: "online", tools: %w[read_file])
    Agent.create!(agent_id: id, state: state, first_seen_at: 1.minute.ago, last_seen_at: Time.current,
                  tools: tools.to_json, packet_count: 0)
  end

  def packet(topic:, payload:, kind:, agent_id: nil, request_id: nil, at: Time.current)
    Packet.create!(topic: topic, payload: payload, kind: kind, agent_id: agent_id,
                   request_id: request_id, occurred_at: at, received_at: at, payload_bytes: payload.bytesize)
  end

  def test_a_delegation_becomes_an_edge_with_its_reply_and_latency
    agent("lead")
    agent("worker")
    t0 = 10.seconds.ago
    packet(topic: "runes/agents/worker/tasks", kind: "task", agent_id: "worker", request_id: "r1",
           payload: JSON.generate("from" => "lead", "request_id" => "r1", "prompt" => "do it"), at: t0)
    packet(topic: "runes/agents/lead/tasks/r1/response", kind: "task_response", agent_id: "lead",
           request_id: "r1", payload: "done", at: t0 + 2.5)

    nodes, edges = FleetTopology.build(agents: Agent.all, packets: Packet.all)
    edge = edges.find { |e| e.from == "lead" && e.to == "worker" }

    refute_nil edge, "a stated from/target pair must become an edge"
    assert_equal 1, edge.tasks
    assert_equal 1, edge.replies
    assert_equal 0, edge.errors
    assert_in_delta 2500, edge.avg_ms, 200
    assert edge.completed?

    lead = nodes.find { |n| n.agent_id == "lead" }
    worker = nodes.find { |n| n.agent_id == "worker" }
    assert_equal 1, lead.outbound
    assert_equal 0, lead.inbound
    assert_equal 1, worker.inbound
    assert_equal 0, worker.outbound
  end

  def test_an_error_reply_is_counted_on_the_edge
    agent("lead")
    agent("worker")
    t0 = 5.seconds.ago
    packet(topic: "runes/agents/worker/tasks", kind: "task", agent_id: "worker", request_id: "r2",
           payload: JSON.generate("from" => "lead", "request_id" => "r2"), at: t0)
    packet(topic: "runes/agents/lead/tasks/r2/response", kind: "task_response", agent_id: "lead",
           request_id: "r2", payload: "Error: unauthorised", at: t0 + 1)

    _nodes, edges = FleetTopology.build(agents: Agent.all, packets: Packet.all)
    edge = edges.find { |e| e.to == "worker" }

    assert_equal 1, edge.errors
    assert_in_delta 1.0, edge.error_rate, 0.001
  end

  def test_an_a2a_task_without_a_sender_is_inbound_work_not_an_edge
    agent("worker")
    packet(topic: "$a2a/v1/tasks/runes/host/worker", kind: "a2a_task", agent_id: "worker",
           request_id: "task-9", payload: JSON.generate("id" => "task-9"))

    nodes, edges = FleetTopology.build(agents: Agent.all, packets: Packet.all)

    assert_empty edges, "the topic names only the receiver: no edge may be invented"
    worker = nodes.find { |n| n.agent_id == "worker" }
    assert_equal 1, worker.inbound
  end

  def test_an_agent_absent_from_the_cards_still_appears_as_a_node
    packet(topic: "runes/agents/ghost/tasks", kind: "task", agent_id: "ghost", request_id: "r3",
           payload: JSON.generate("from" => "lead", "request_id" => "r3"))

    nodes, = FleetTopology.build(agents: Agent.all, packets: Packet.all)
    ids = nodes.map(&:agent_id)

    assert_includes ids, "ghost"
    assert_includes ids, "lead"
  end

  def test_execution_and_errors_are_attributed_to_the_agent_that_did_the_work
    agent("worker")
    packet(topic: "runes/prompts/r4/progress", kind: "progress", agent_id: "worker", request_id: "r4",
           payload: JSON.generate("event" => "plan_ready"))
    packet(topic: "runes/prompts/r4/progress", kind: "progress", agent_id: "worker", request_id: "r4",
           payload: JSON.generate("event" => "step_end"))
    packet(topic: "runes/tools/run_command/error", kind: "tool_error", agent_id: "worker",
           payload: "Error: refused")

    nodes, = FleetTopology.build(agents: Agent.all, packets: Packet.all)
    worker = nodes.find { |n| n.agent_id == "worker" }

    assert_equal 2, worker.executed
    assert_equal 1, worker.errors
    assert_equal 1, worker.tools
    assert_equal "online", worker.display_state
  end

  def test_self_delegation_does_not_create_a_self_loop
    agent("solo")
    packet(topic: "runes/agents/solo/tasks", kind: "task", agent_id: "solo", request_id: "r5",
           payload: JSON.generate("from" => "solo", "request_id" => "r5"))

    nodes, edges = FleetTopology.build(agents: Agent.all, packets: Packet.all)

    assert_empty edges
    solo = nodes.find { |n| n.agent_id == "solo" }
    assert_equal 1, solo.inbound
    assert_equal 0, solo.outbound, "a task to yourself is not an outbound edge"
  end

  def test_an_empty_fleet_is_an_empty_graph
    nodes, edges = FleetTopology.build(agents: Agent.all, packets: Packet.all)

    assert_empty nodes
    assert_empty edges
  end
end
