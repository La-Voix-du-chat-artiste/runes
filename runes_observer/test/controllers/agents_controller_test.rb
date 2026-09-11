require "test_helper"

class AgentsControllerTest < ActionDispatch::IntegrationTest
  test "index lists every observed agent with its state" do
    get agents_path

    assert_response :success
    assert_match "runes-alpha", response.body
    assert_match "runes-beta", response.body
    assert_match "online", response.body
    assert_match "offline", response.body
  end

  test "index filters by state" do
    get agents_path(state: "offline")

    assert_response :success
    assert_match "runes-beta", response.body
    assert_no_match(/runes-alpha/, response.body)
  end

  test "index filters by search query" do
    get agents_path(q: "beta")

    assert_response :success
    assert_match "runes-beta", response.body
    assert_no_match(/runes-alpha/, response.body)
  end

  test "show renders identity, card, interactions and packet history" do
    get agent_path("runes-alpha")

    assert_response :success
    assert_match "runes.dispatcher", response.body
    assert_match "Agent card", response.body
    assert_match "Interactions", response.body
    assert_match "request:req-1", response.body
    assert_match "write a greeting file", response.body
    assert_match "Packet history", response.body
  end

  test "show explains an agent that was never observed" do
    get agent_path("runes-ghost")

    assert_redirected_to agents_path
    follow_redirect!
    assert_match "No agent #runes-ghost", response.body
  end

  # O5-4 regression: the page used to render every packet of every
  # interaction (48.9 MB at 200k rows). It must be bounded and paginated.
  test "show stays bounded for an agent with many large interactions" do
    now = Time.current
    agent_id = "runes-busy"
    Agent.create!(agent_id: agent_id, first_seen_at: now, last_seen_at: now, state: "online")

    payload = "y" * 32.kilobytes
    rows = []
    40.times do |i|
      20.times do
        rows << { topic: "runes/prompts/req-b#{i}/progress", payload: payload,
                  payload_bytes: payload.bytesize, truncated: false, scrubbed: false,
                  agent_id: agent_id, request_id: "req-b#{i}", kind: "progress",
                  event: "step_end", tool: nil, occurred_at: now, received_at: now,
                  created_at: now, updated_at: now }
      end
    end
    rows << { topic: "runes/prompts", payload: '{"request_id":"req-b0","prompt":"busy prompt"}',
              payload_bytes: 45, truncated: false, scrubbed: false, agent_id: agent_id,
              request_id: "req-b0", kind: "prompt", event: nil, tool: nil,
              occurred_at: now, received_at: now, created_at: now, updated_at: now }
    Packet.insert_all(rows)

    get agent_path(agent_id)

    assert_response :success
    assert_operator response.body.bytesize, :<, 2.megabytes,
                    "the agent page must not render every packet of every interaction"
    assert_match "Interactions", response.body
    assert_match "request:req-b", response.body
    assert_match "page 1 of 3", response.body
  end
  # O0.3 on the fleet member itself: which keys has this agent published under?
  test "the agent page lists the signing keys it has been seen with" do
    first = "11" * 32
    second = "22" * 32
    2.times do |i|
      Packet.create!(topic: "runes/prompts", kind: "prompt", payload: "{}", payload_bytes: 2,
                     agent_id: "runes-alpha", signature_state: "verified",
                     key_fingerprint: [first, second][i], occurred_at: Time.current,
                     received_at: Time.current)
    end

    get agent_path("runes-alpha")

    assert_response :success
    assert_match "signing keys", response.body
    assert_match "11" * 12, response.body
    assert_match "22" * 12, response.body
    assert_match "more than one key", response.body
    assert_match "kv__warn", response.body
  end
end
