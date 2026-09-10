require "test_helper"

# Walks one observed interaction the way an operator would: record it like
# the ingest process would, then dashboard → agent → interaction → filtered
# packet log → JSON feed.
class ObserverFlowTest < ActionDispatch::IntegrationTest
  test "a recorded interaction is visible on every page" do
    record_interaction

    get root_path
    assert_response :success
    assert_match "runes-flow", response.body
    assert_match "flow please", response.body

    get agent_path("runes-flow")
    assert_response :success
    assert_match "request:flow-1", response.body
    assert_match "Wrote flow.rb", response.body
    assert_match "online", response.body

    get interaction_path("flow-1")
    assert_response :success
    assert_match "step_end", response.body
    assert_match "run_command", response.body
    assert_match "runes-flow", response.body

    get packets_path(agent_id: "runes-flow", kind: "progress")
    assert_response :success
    assert_match "runes/prompts/flow-1/progress", response.body

    get feed_path(agent_id: "runes-flow", after_id: 0), as: :json
    assert_response :success
    body = JSON.parse(response.body)
    assert_operator body["packets"].size, :>=, 6
    assert(body["packets"].all? { |packet| packet["html"].present? })
    assert(body["packets"].any? { |packet| packet["html"].include?("runes-flow") })
  end

  test "an ended agent shows up as ended, not running" do
    record_interaction
    record "runes/agents/runes-flow/status", "offline"

    get root_path
    assert_response :success
    assert_match "Ended", response.body

    get agent_path("runes-flow")
    assert_response :success
    assert_match "offline", response.body
    assert_match "ended", response.body
  end

  private

  def record_interaction
    record "runes/agents/runes-flow/card",
           JSON.generate("name" => "runes-flow", "kind" => "runes.dispatcher",
                         "version" => "0.2.0", "workspace" => "/tmp/runes-flow",
                         "tools" => %w[write_file run_command])
    record "runes/agents/runes-flow/status", "online"
    record "runes/prompts",
           JSON.generate("request_id" => "flow-1", "prompt" => "flow please", "mode" => "build")
    record "runes/prompts/flow-1/progress",
           JSON.generate("event" => "step_end", "step" => 1, "tool" => "write_file",
                         "outcome" => "Wrote flow.rb (12B)")
    record "runes/prompts/flow-1/progress",
           JSON.generate("event" => "step_end", "step" => 2, "tool" => "run_command",
                         "outcome" => "exit=0")
    record "runes/prompts/flow-1/progress", JSON.generate("event" => "prompt_complete")
    record "runes/prompts/flow-1/response",
           "Plan for: flow please\n  1. write_file -> Wrote flow.rb"
    # The trailing journal entry is how the executor becomes known; it
    # backfills attribution for the whole request.
    record "runes/_log/prompts",
           JSON.generate("request_id" => "flow-1", "agent" => "runes-flow",
                         "status" => "complete", "summary" => "Plan for: flow please")
  end

  def record(topic, payload)
    PacketRecorder.record(topic: topic, payload: payload)
  end
end
