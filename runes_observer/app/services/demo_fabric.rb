# Seeds a realistic Runes session through the SAME PacketRecorder the live
# ingest uses, so `bin/rails runes:demo` produces exactly the rows the UI
# would show for a real bus — there is no second, drifting code path.
#
# Emits only the Phase 17 vocabulary the harness actually publishes, per
# prompt: agent card + status, the broadcast prompt envelope, streaming
# progress, the correlated response, and the trailing journal entry that
# names the executor (which backfills agent attribution for the request).
# One agent is left offline (LWT) so the fleet view has an "ended" row.
#
# The claim/started/session-lease topics this seeder used to invent were
# deleted with the protocol in Phase 16 (X5-1).
class DemoFabric
  ONLINE_AGENT = "runes-studio-4012"
  ENDED_AGENT  = "runes-studio-4013"
  GOAL_REQUEST = "g04l01"

  PROMPTS = [
    { id: "d3m0a1", text: "Create hello.rb defining a method `greet` that returns \"hello world\", " \
                          "then run its minitest.",
      steps: [
        { tool: "write_file", out: "Wrote hello.rb (30B)" },
        { tool: "write_file", out: "Wrote hello_test.rb (151B)" },
        { tool: "run_command", out: "exit=0 output:\n1 runs, 1 assertions, 0 failures, 0 errors" }
      ] },
    { id: "d3m0a2", text: "Add a CHANGELOG entry for the observer and verify the file reads back.",
      steps: [
        { tool: "read_file", out: "CHANGELOG.md (412B)" },
        { tool: "write_file", out: "Wrote CHANGELOG.md (489B)" }
      ] }
  ].freeze

  def self.seed!(reset: true)
    new(reset: reset).seed!
  end

  def initialize(reset: false)
    @reset = reset
    @clock = 12.minutes.ago
  end

  def seed!
    clear! if @reset
    [ONLINE_AGENT, ENDED_AGENT].each { |id| emit_card(id) }
    emit_status(ONLINE_AGENT, "online")
    emit_status(ENDED_AGENT, "online")

    PROMPTS.each_with_index do |prompt, index|
      agent = index.zero? ? ONLINE_AGENT : ENDED_AGENT
      emit_prompt_flow(agent, prompt)
    end

    emit_tool_rpc
    emit_goal_flow
    # Last Will: the second agent ends while the first keeps running.
    emit_status(ENDED_AGENT, "offline")
    true
  end

  private

  def clear!
    Packet.delete_all
    Agent.delete_all
    IngestStatus.delete_all
  end

  def tick(seconds = 1 + rand(3))
    @clock += seconds.seconds
  end

  def emit(topic, payload, at = tick)
    body = payload.is_a?(String) ? payload : JSON.generate(payload)
    PacketRecorder.record(topic: topic, payload: body, occurred_at: at, received_at: at)
  end

  def emit_card(agent_id)
    emit("runes/agents/#{agent_id}/card", {
      "name" => agent_id,
      "kind" => "runes.dispatcher",
      "version" => "0.2.0",
      "workspace" => "/Users/dev/projects/runes/workspace",
      "tools" => %w[write_file read_file run_command echo],
      "tools_registered" => [
        { "name" => "echo", "description" => "echoes its args", "version" => "1.0.0" }
      ],
      "wasm_backend" => "mock",
      "wasm_mock" => true,
      "started_at" => @clock.utc.iso8601
    })
  end

  def emit_status(agent_id, state)
    emit("runes/agents/#{agent_id}/status", state, tick(2))
  end

  def emit_prompt_flow(agent_id, prompt)
    topic_base = "runes/prompts/#{prompt[:id]}"
    emit("runes/prompts", { "request_id" => prompt[:id], "prompt" => prompt[:text],
                            "mode" => "build", "session_id" => nil })
    emit("#{topic_base}/progress", { "event" => "prompt_received", "request_id" => prompt[:id],
                                     "prompt" => prompt[:text] })
    emit("#{topic_base}/progress", { "event" => "plan_ready", "request_id" => prompt[:id],
                                     "steps" => prompt[:steps].size })
    prompt[:steps].each_with_index do |step, index|
      emit("#{topic_base}/progress", { "event" => "step_start", "step" => index + 1, "tool" => step[:tool] })
      emit("#{topic_base}/progress", { "event" => "step_end", "step" => index + 1,
                                       "tool" => step[:tool], "outcome" => step[:out] })
    end
    emit("#{topic_base}/progress", { "event" => "prompt_complete", "request_id" => prompt[:id] })
    summary = +"Plan for: #{prompt[:text]}\n"
    prompt[:steps].each_with_index { |s, i| summary << "  #{i + 1}. #{s[:tool]} -> #{s[:out]}\n" }
    emit("#{topic_base}/response", summary, tick(1))
    emit("runes/prompts/response", summary, tick(0))
    emit("runes/_log/prompts", { "request_id" => prompt[:id], "agent" => agent_id,
                                 "prompt" => prompt[:text], "status" => "complete",
                                 "summary" => "Plan for: #{prompt[:text]}",
                                 "at" => tick(0).utc.iso8601 })
  end

  def emit_tool_rpc
    emit("runes/tools/run_command/request", { "cmd" => "ruby hello_test.rb", "token" => "[redacted]" })
    emit("runes/tools/run_command/response", "exit=0 output:\n1 runs, 1 assertions, 0 failures", tick(1))
  end

  # A goal-mode turn: the same /progress + /response topics with mode=goal,
  # attributed by its trailing journal entry.
  def emit_goal_flow
    prompt = "What is the smallest useful first release?"
    topic_base = "runes/prompts/#{GOAL_REQUEST}"
    emit("runes/prompts", { "request_id" => GOAL_REQUEST, "prompt" => prompt,
                            "mode" => "goal", "session_id" => nil })
    emit("#{topic_base}/progress", { "event" => "conversation", "session_id" => GOAL_REQUEST,
                                     "text" => "Rubber-duck reply: clarify the target user first." })
    emit("#{topic_base}/response", "Rubber-duck reply: clarify the target user first.", tick(1))
    emit("runes/_log/prompts", { "request_id" => GOAL_REQUEST, "agent" => ONLINE_AGENT,
                                 "prompt" => prompt, "status" => "goal_turn",
                                 "summary" => "Rubber-duck reply: clarify the target user first.",
                                 "at" => tick(0).utc.iso8601 })
  end
end
