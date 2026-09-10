require "test_helper"

class TopologyControllerTest < ActionDispatch::IntegrationTest
  setup do
    Packet.delete_all
    Agent.delete_all
  end

  def agent(id, state: "online")
    Agent.create!(agent_id: id, state: state, first_seen_at: 1.minute.ago, last_seen_at: Time.current,
                  tools: %w[read_file write_file].to_json, packet_count: 3)
  end

  def packet(topic:, payload:, kind:, agent_id: nil, request_id: nil, at: Time.current)
    Packet.create!(topic: topic, payload: payload, kind: kind, agent_id: agent_id,
                   request_id: request_id, occurred_at: at, received_at: at, payload_bytes: payload.bytesize)
  end

  def seed_delegation
    agent("lead")
    agent("worker")
    t0 = 6.seconds.ago
    packet(topic: "runes/agents/worker/tasks", kind: "task", agent_id: "worker", request_id: "r1",
           payload: JSON.generate("from" => "lead", "request_id" => "r1"), at: t0)
    packet(topic: "runes/agents/lead/tasks/r1/response", kind: "task_response", agent_id: "lead",
           request_id: "r1", payload: "done", at: t0 + 1.5)
  end

  def test_the_graph_renders_wires_and_nodes
    seed_delegation

    get topology_path

    assert_response :success
    assert_match "Fleet graph", response.body
    # one wire per delegation, with the arrow marker
    assert_equal 1, response.body.scan(/class="wire wire--ok"/).size
    assert_match(/marker-end="url\(#arrow-ok\)"/, response.body)
    # both ends drawn as nodes, labelled
    assert_equal 2, response.body.scan(/class="topo-node topo-node--/).size
    assert_match(/>lead</, response.body)
    assert_match(/>worker</, response.body)
  end

  def test_the_link_table_carries_the_numbers
    seed_delegation

    get topology_path

    assert_match "Delegation links", response.body
    assert_match(/lead<\/a>/, response.body)
    assert_match(/worker<\/a>/, response.body)
    # the average latency of the round trip is shown
    assert_match(/1\.5s|1500ms/, response.body)
  end

  def test_error_links_are_drawn_differently
    agent("lead")
    agent("worker")
    packet(topic: "runes/agents/worker/tasks", kind: "task", agent_id: "worker", request_id: "r9",
           payload: JSON.generate("from" => "lead", "request_id" => "r9"))
    packet(topic: "runes/agents/lead/tasks/r9/response", kind: "task_response", agent_id: "lead",
           request_id: "r9", payload: "Error: refused")

    get topology_path

    assert_equal 1, response.body.scan(/class="wire wire--error"/).size
  end

  def test_an_empty_fleet_explains_itself_instead_of_drawing_nothing
    get topology_path

    assert_response :success
    assert_match(/No agents observed yet/, response.body)
    assert_match(/bin\/runes-daemon/, response.body)
  end

  def test_inbound_work_without_a_stated_sender_is_reported_not_drawn
    agent("worker")
    packet(topic: "$a2a/v1/tasks/runes/host/worker", kind: "a2a_task", agent_id: "worker",
           payload: JSON.generate("id" => "t-1"))

    get topology_path

    assert_response :success
    assert_match(/1 inbound with no stated sender/, response.body)
    assert_equal 0, response.body.scan(/class="wire wire--/).size
  end
end
