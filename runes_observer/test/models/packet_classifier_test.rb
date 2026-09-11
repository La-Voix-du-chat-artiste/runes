require "test_helper"

# The whole Runes topic grammar, in one table — this is what every view's
# grouping depends on, so it is tested exhaustively.
class PacketClassifierTest < ActiveSupport::TestCase
  def classify(topic, payload = "{}")
    PacketClassifier.call(topic: topic, payload: payload)
  end

  test "agent card and status topics carry the agent id" do
    card = classify("runes/agents/runes-a/card", '{"name":"runes-a"}')
    assert_equal "card", card.kind
    assert_equal "runes-a", card.agent_id

    status = classify("runes/agents/runes-a/status", "online")
    assert_equal "status", status.kind
    assert_equal "runes-a", status.agent_id
  end

  test "delegation topics" do
    task = classify("runes/agents/runes-a/tasks", '{"request_id":"t1"}')
    assert_equal "task", task.kind
    assert_equal "runes-a", task.agent_id
    assert_equal "t1", task.request_id

    reply = classify("runes/agents/runes-a/tasks/t1/response", "done")
    assert_equal "task_response", reply.kind
    assert_equal "runes-a", reply.agent_id
    assert_equal "t1", reply.request_id
  end

  test "prompt broadcast and global response" do
    prompt = classify("runes/prompts", '{"request_id":"r1","prompt":"hi","mode":"build"}')
    assert_equal "prompt", prompt.kind
    assert_equal "r1", prompt.request_id
    assert_nil prompt.agent_id

    global = classify("runes/prompts/response", "summary")
    assert_equal "response_global", global.kind
  end

  test "request lifecycle topics" do
    progress = classify("runes/prompts/r1/progress", '{"event":"step_end"}')
    assert_equal "progress", progress.kind
    assert_equal "r1", progress.request_id
    assert_equal "step_end", progress.event

    response = classify("runes/prompts/r1/response", "done")
    assert_equal "response", response.kind
    assert_equal "r1", response.request_id
  end

  test "the deleted claim/started/session grammar is not matched" do
    [
      "runes/prompts/r1/claim",
      "runes/prompts/r1/started",
      "runes/sessions/s-1/claim",
      "runes/sessions/s-1/started"
    ].each do |topic|
      result = classify(topic, '{"agent":"runes-a"}')
      assert_equal "other", result.kind, topic
      assert_nil result.agent_id, topic
      assert_nil result.request_id, topic
    end
  end

  test "an envelope may name its executor with agent or from" do
    from = classify("runes/prompts/r1/progress", '{"event":"x","from":"runes-sender"}')
    assert_equal "runes-sender", from.agent_id

    agent = classify("runes/prompts/r1/response", '{"agent":"runes-exec"}')
    assert_equal "runes-exec", agent.agent_id

    # `agent` wins when both are present.
    both = classify("runes/prompts/r1/progress", '{"agent":"runes-exec","from":"runes-sender"}')
    assert_equal "runes-exec", both.agent_id
  end

  test "tool rpc topics expose the tool name" do
    assert_equal "tool_request", classify("runes/tools/run_command/request", '{"cmd":"ls"}').kind
    assert_equal "run_command", classify("runes/tools/run_command/request", "{}").tool
    assert_equal "tool_response", classify("runes/tools/echo/response", "hi").kind
    assert_equal "tool_error", classify("runes/tools/echo/error", "boom").kind
  end

  test "journal topics include the retained latest snapshot" do
    entry = '{"request_id":"r1","agent":"runes-a","status":"complete"}'
    assert_equal "journal", classify("runes/_log/prompts", entry).kind
    assert_equal "runes-a", classify("runes/_log/prompts", entry).agent_id

    latest = classify("runes/_log/prompts/latest", entry)
    assert_equal "journal", latest.kind
    assert_equal "r1", latest.request_id
  end

  test "A2A discovery and task topics use the A2A kinds" do
    card = classify("$a2a/v1/discovery/runes/host-a/runes-abc123",
                    JSON.generate("protocolVersion" => "0.3.0",
                                  "name" => "runes-abc123"))
    assert_equal "a2a_card", card.kind
    assert_equal "runes-abc123", card.agent_id
    assert_nil card.request_id

    task = classify("$a2a/v1/tasks/runes/host-a/runes-abc123",
                    JSON.generate("taskId" => "task-1"))
    assert_equal "a2a_task", task.kind
    assert_equal "runes-abc123", task.agent_id
    assert_equal "task-1", task.request_id
  end

  test "a2a-prefixed topics with too few segments fall back to other" do
    [
      "$a2a", "$a2a/", "$a2a/v1", "$a2a/v1/discovery",
      "$a2a/v1/discovery/runes", "$a2a/v1/discovery/runes/host-a",
      "$a2a/v1/tasks", "$a2a/v1/tasks/runes", "$a2a/v1/tasks/runes/host-a",
      "$a2a/v1/discovery/runes/host-a/runes-abc123/extra"
    ].each do |topic|
      result = classify(topic, "{}")
      assert_equal "other", result.kind, topic
      assert_nil result.agent_id, topic
    end
  end

  test "an A2A agent card exposes its x-runes metadata at the top level" do
    payload = JSON.generate(
      "protocolVersion" => "0.3.0",
      "name" => "runes-abc123",
      "version" => "1.2.3",
      "skills" => [{ "id" => "read_file" }],
      "x-runes" => { "kind" => "runes.dispatcher",
                     "workspace" => "/tmp/ws",
                     "tools" => %w[read_file echo] }
    )

    data = PacketClassifier.parse(payload)
    assert_equal %w[read_file echo], data["tools"]
    assert_equal "/tmp/ws", data["workspace"]
    assert_equal "runes.dispatcher", data["kind"]
    # A2A's own fields are untouched, and the extension stays visible.
    assert_equal "0.3.0", data["protocolVersion"]
    assert_equal [{ "id" => "read_file" }], data["skills"]
    assert data.key?("x-runes")
  end

  test "a legacy card payload passes through unchanged" do
    data = PacketClassifier.parse(JSON.generate("name" => "runes-a", "tools" => %w[ls]))
    assert_equal "runes-a", data["name"]
    assert_equal %w[ls], data["tools"]
    assert_not data.key?("x-runes")
  end

  test "unknown topics fall back to other" do
    assert_equal "other", classify("runes/whatever", "x").kind
  end

  test "non-JSON and non-object payloads do not raise" do
    assert_nil classify("runes/prompts", "not json").request_id
    assert_nil classify("runes/prompts", "[1,2,3]").request_id
    assert_nil classify("runes/prompts", "").request_id
  end
  # doc5.md O2.3: a refusal is a packet like any other, and the fields the
  # security page groups by (tool, action, agent) come from the payload.
  test "a guard denial carries who was refused, for what, by whom" do
    result = classify("runes/guard/denied",
                      JSON.generate("tool" => "run_command", "action" => "exec",
                                    "resource" => "/etc/passwd", "agent" => "runes-a",
                                    "decision" => "denied"))

    assert_equal "guard_denied", result.kind
    assert_equal "run_command", result.tool
    assert_equal "exec", result.event
    assert_equal "runes-a", result.agent_id
    assert_includes Packet::KINDS, "guard_denied"
  end

  test "a guard denial with no payload still classifies" do
    assert_equal "guard_denied", classify("runes/guard/denied", "not json").kind
    assert_equal "guard_denied", classify("runes/guard/denied", "").kind
  end

  test "the guard topic is exact: a deeper topic is not a denial" do
    assert_equal "other", classify("runes/guard/denied/extra").kind
    assert_equal "other", classify("runes/guard/allowed").kind
  end
end
