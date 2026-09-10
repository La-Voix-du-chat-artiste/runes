require "test_helper"

class InteractionsControllerTest < ActionDispatch::IntegrationTest
  test "shows every packet of a request, oldest first" do
    get interaction_path("req-1")

    assert_response :success
    assert_match "write a greeting file", response.body
    assert_match "runes/prompts/req-1/response", response.body
    assert_match "runes-alpha", response.body
    assert_match "request", response.body
  end

  test "groups a delegated task reply under its request id" do
    get interaction_path("req-2")

    assert_response :success
    assert_match "runes/agents/runes-beta/tasks/req-2/response", response.body
    assert_match "runes-beta", response.body
  end

  # The waterfall is the point of the page: a long pause must be drawn, and
  # named, rather than left for the reader to infer from timestamps.
  test "draws a waterfall and calls out the dominant gap" do
    Packet.delete_all
    base = 20.seconds.ago
    Packet.create!(topic: "runes/prompts/gap-1", kind: "prompt", request_id: "gap-1",
                   agent_id: "runes-alpha", payload: JSON.generate("prompt" => "slow one"),
                   occurred_at: base, received_at: base, payload_bytes: 4)
    Packet.create!(topic: "runes/prompts/gap-1/progress", kind: "progress", request_id: "gap-1",
                   agent_id: "runes-alpha", event: "plan_ready", payload: JSON.generate("event" => "plan_ready"),
                   occurred_at: base + 9, received_at: base + 9, payload_bytes: 2)
    Packet.create!(topic: "runes/prompts/gap-1/response", kind: "response", request_id: "gap-1",
                   agent_id: "runes-alpha", payload: "done",
                   occurred_at: base + 9.3, received_at: base + 9.3, payload_bytes: 4)

    get interaction_path("gap-1")

    assert_response :success
    assert_match "Where the time went", response.body
    assert_match "dominated by", response.body
    assert_match "progress · plan_ready", response.body
    # one bar per gap (3 packets => 2 gaps)
    assert_equal 2, response.body.scan(/class="trace__gap/).size
    # the dominant gap is drawn in its own colour
    assert_equal 1, response.body.scan(/trace__gap--dominant/).size
  end

  test "an unknown correlation id renders an empty timeline" do
    get interaction_path("nope")

    assert_response :success
    assert_match "No packet carries this id", response.body
  end
end
