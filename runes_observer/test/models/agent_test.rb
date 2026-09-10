require "test_helper"

class AgentTest < ActiveSupport::TestCase
  test "record_card! stores card metadata but never flips state" do
    agent = Agent.record_card!("runes-new", {
      "name" => "runes-new", "kind" => "runes.dispatcher", "version" => "0.2.0",
      "workspace" => "/tmp/ws", "tools" => %w[write_file read_file]
    })

    assert_equal "unknown", agent.state, "a retained card must not claim the agent is online"
    assert_equal "runes-new", agent.name
    assert_equal "runes.dispatcher", agent.kind
    assert_equal "/tmp/ws", agent.workspace
    assert_equal %w[write_file read_file], agent.tools_list
    assert_equal "runes-new", agent.card_hash["name"]
  end

  test "record_status! tracks online, offline and resurrection" do
    Agent.record_status!("runes-x", "online")
    assert Agent.find_by(agent_id: "runes-x").online?

    Agent.record_status!("runes-x", "offline")
    ended = Agent.find_by(agent_id: "runes-x")
    assert ended.ended?
    assert_not_nil ended.ended_at

    Agent.record_status!("runes-x", "online")
    back = Agent.find_by(agent_id: "runes-x")
    assert back.online?
    assert_nil back.ended_at
  end

  test "touch_seen! creates a stub and does not touch the packet counter" do
    agent = Agent.touch_seen!("runes-stub")
    assert_equal "unknown", agent.state
    assert_equal 0, agent.packet_count

    Agent.touch_seen!("runes-stub")
    assert_equal 0, Agent.find_by(agent_id: "runes-stub").packet_count
  end

  test "bump_packet_count! advances the counter maintained by the recorder" do
    Agent.touch_seen!("runes-counted")
    assert_equal 1, Agent.bump_packet_count!("runes-counted").packet_count
    assert_equal 4, Agent.bump_packet_count!("runes-counted", by: 3).packet_count
    assert_nil Agent.bump_packet_count!("runes-never-seen")
  end

  test "search treats LIKE metacharacters literally" do
    Agent.create!(agent_id: "runes-100%", first_seen_at: Time.current, last_seen_at: Time.current)
    Agent.create!(agent_id: "runes-100x", first_seen_at: Time.current, last_seen_at: Time.current)

    results = Agent.search("100%")
    assert_equal ["runes-100%"], results.pluck(:agent_id)
  end

  test "display_state reports stale for a silent online agent" do
    agents(:online_agent).update!(last_seen_at: 10.minutes.ago)
    assert_equal "stale", agents(:online_agent).display_state
  end

  test "search matches id, name and workspace" do
    assert_includes Agent.search("alpha"), agents(:online_agent)
    assert_includes Agent.search("runes-beta"), agents(:offline_agent)
    assert_empty Agent.search("no-such-agent")
    assert_equal Agent.count, Agent.search("").count
  end

  test "to_param addresses agents by fabric id" do
    assert_equal "runes-alpha", agents(:online_agent).to_param
  end
end
