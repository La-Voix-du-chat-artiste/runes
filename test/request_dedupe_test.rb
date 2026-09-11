# frozen_string_literal: true

require_relative "test_helper"
require_relative "../lib/runes/core/dispatcher"
require_relative "../lib/runes/request_ledger"

# Distribution is exactly-once via MQTT 5 shared subscriptions; *execution* was
# not covered at all. A QoS 1 PUBLISH whose PUBACK was lost is retransmitted, a
# session-expiry replay comes back after a reconnect, and any publisher that
# retries on timeout sends the same request again — and every one of those used
# to run the prompt a second time: two LLM bills, two sets of tool side effects.
class RequestDedupeTest < Minitest::Test
  # Counts planner calls, so "ran once" is measured, not assumed. Returns a
  # text answer: no tool calls, so nothing touches the filesystem.
  class CountingLLM
    attr_reader :calls

    def initialize
      @calls = 0
      @mutex = Mutex.new
    end

    def call(_prompt, **_options)
      @mutex.synchronize { @calls += 1 }
      { ok: true, mode: :text, content: "done", raw: {}, tool_calls: [] }
    end
  end

  def setup
    @tmp = Dir.mktmpdir("runes-dedupe-")
    @tools = Dir.mktmpdir("runes-dedupe-tools-")
    @settings = Runes::Core::Settings.new(root: @tmp)
    @transport = RecordingTransport.new
    ENV["RUNES_WORKSPACE"] = File.join(@tmp, "workspace")
  end

  def teardown
    # force: workers may still be writing inside the workspace when the test
    # ends, and a flaky ENOTEMPTY is not a finding.
    [@tmp, @tools].each { |dir| FileUtils.remove_entry(dir, true) if dir && Dir.exist?(dir) }
    ENV.delete("RUNES_WORKSPACE")
  end

  def dispatcher(ledger: nil)
    d = Runes::Core::Dispatcher.new(
      { host: "127.0.0.1", port: 0 }, nil, nil,
      settings: @settings, agent_id: "dedupe-agent",
      tool_registry: Runes::Core::ToolRegistry.new(tools_dir: @tools),
      transport: @transport,
      request_ledger: ledger || Runes::RequestLedger.new
    )
    @llm = CountingLLM.new
    d.instance_variable_set(:@llm, @llm)
    d
  end

  def envelope(request_id, prompt = "write a greeting file")
    JSON.generate("request_id" => request_id, "prompt" => prompt)
  end

  def topics = @transport.published.map { |message| message[:topic] }
  def payloads = @transport.published.map { |message| message[:payload].to_s }
  def events = payloads.filter_map { |payload| JSON.parse(payload)["event"] rescue nil }

  # --- the bug this exists for -------------------------------------------

  def test_a_redelivered_request_runs_the_planner_once
    d = dispatcher
    topic = "runes/prompts/dup-1/response"

    3.times { d.handle_payload(envelope("dup-1"), reply_topic: topic) }

    assert_equal 1, @llm.calls, "the same request_id must run once, however often it is delivered"
  end

  def test_the_duplicate_is_announced_rather_than_silently_dropped
    d = dispatcher
    d.handle_payload(envelope("dup-2"), reply_topic: "runes/prompts/dup-2/response")
    d.handle_payload(envelope("dup-2"), reply_topic: "runes/prompts/dup-2/response")

    assert_includes events, "duplicate_ignored"
    ignored = payloads.find { |p| p.include?("duplicate_ignored") }
    assert_equal "dup-2", JSON.parse(ignored)["request_id"]
  end

  # The interesting half of "exactly once": the *second* copy is not just
  # dropped, the sender still gets an answer — from the ledger.
  def test_a_duplicate_after_completion_is_answered_from_the_ledger
    d = dispatcher
    topic = "runes/prompts/dup-3/response"

    d.handle_payload(envelope("dup-3"), reply_topic: topic)
    assert_equal 1, @llm.calls
    @transport.published.clear

    d.handle_payload(envelope("dup-3"), reply_topic: topic)

    assert_equal 1, @llm.calls, "the planner must not be called again"
    answer = @transport.published.find { |m| m[:topic] == topic }
    refute_nil answer, "the replay must still be answered on the reply topic"
    assert_includes answer[:payload], "Duplicate request ignored"
    # The outcome the first copy recorded (its status), so the sender can tell
    # a replay from a fresh run without reading the ledger.
    assert_match(/already \w+/, answer[:payload])
  end

  # A plain prompt has no request id to dedupe on: its id is a digest of its
  # text, so two deliberate repeats of the same line look exactly like one
  # retry. Re-running is the lesser evil.
  def test_two_deliberate_plain_prompts_both_run
    d = dispatcher

    2.times { d.handle_payload("say hello") }

    assert_equal 2, @llm.calls
    refute_includes events, "duplicate_ignored"
  end

  def test_different_requests_are_not_confused_with_each_other
    d = dispatcher
    d.handle_payload(envelope("req-a"), reply_topic: "runes/prompts/req-a/response")
    d.handle_payload(envelope("req-b"), reply_topic: "runes/prompts/req-b/response")

    assert_equal 2, @llm.calls
    refute_includes events, "duplicate_ignored"
  end

  def test_the_ledger_expiry_is_what_allows_a_reused_id
    clock = -> { @now ||= 1_000.0 }
    ledger = Runes::RequestLedger.new(ttl: 60, clock: clock)
    d = dispatcher(ledger: ledger)

    d.handle_payload(envelope("reused"), reply_topic: "runes/prompts/reused/response")
    assert_equal 1, @llm.calls

    @now += 61 # past the window: a re-used id is a new request
    d.handle_payload(envelope("reused"), reply_topic: "runes/prompts/reused/response")

    assert_equal 2, @llm.calls
  end

  # The opt-in direct tool RPC gets the same treatment: an RPC delivered twice
  # must not run a tool twice.
  def test_a_redelivered_tool_rpc_runs_the_tool_once
    d = dispatcher
    calls = Queue.new
    d.define_singleton_method(:handle_tool_request) { |*_args| calls << 1 }
    payload = JSON.generate("request_id" => "rpc-1", "args" => {})

    2.times { d.dispatch_tool_request("read_file", payload) }
    sleep 0.1 until calls.size >= 1 || @transport.published.any? { |m| m[:topic].end_with?("/error") }

    assert_equal 1, calls.size, "the tool must run once"
    error = @transport.published.find { |m| m[:topic] == "runes/tools/read_file/error" }
    refute_nil error, "the duplicate must be told why nothing happened"
    assert_includes error[:payload], "duplicate"
  end

  def test_a_tool_rpc_without_a_request_id_is_never_deduped
    d = dispatcher
    calls = Queue.new
    d.define_singleton_method(:handle_tool_request) { |*_args| calls << 1 }

    2.times { d.dispatch_tool_request("read_file", JSON.generate("args" => {})) }
    sleep 0.05 while calls.size < 2

    assert_equal 2, calls.size
  end
  # Delegation is where a peer retry matters most, and the delegation envelope
  # carries a verified request id even when the delegated prompt is a plain
  # string — the fabric adopts it so the inner request has an identity.
  def test_a_redelivered_delegation_with_a_plain_prompt_runs_once
    d = dispatcher
    payload = JSON.generate("prompt" => "do the delegated thing",
                            "from" => "runes-peer", "request_id" => "deleg-1",
                            "at" => Time.now.utc.iso8601)

    d.handle_delegated_task(payload)
    assert_equal 1, @llm.calls

    d.handle_delegated_task(payload)

    assert_equal 1, @llm.calls, "one delegation, however often the peer retries it"
    assert_includes events, "duplicate_ignored"
  end

  # An A2A task carries its task id as request_id, so it is deduped by the same
  # claim as a prompt.
  def test_a_redelivered_a2a_task_runs_once
    d = dispatcher
    task = Runes::A2A::Task.request(prompt: "answer the A2A task", task_id: "a2a-1")
    message = Runes::Transport::Message.new(
      topic: "\$a2a/v1/tasks/runes/host/dedupe-agent",
      payload: JSON.generate(task),
      properties: { response_topic: "runes/prompts/a2a-1/response" }
    )

    d.handle_a2a_task(message)
    assert_equal 1, @llm.calls

    d.handle_a2a_task(message)

    assert_equal 1, @llm.calls, "an A2A redelivery must not run the task twice"
  end
  # Everything above calls `handle_prompt` directly. This one goes through a
  # real transport subscription, so the guarantee is pinned where a redelivery
  # actually arrives — a future refactor that moves the claim out of the
  # delivery path fails here, not in production.
  def test_a_duplicate_delivered_by_the_transport_runs_once
    hub = Runes::Transport::InProcess.new.connect
    ledger = Runes::RequestLedger.new
    d = Runes::Core::Dispatcher.new(
      { host: "127.0.0.1", port: 0 }, nil, nil,
      settings: @settings, agent_id: "wire-agent",
      tool_registry: Runes::Core::ToolRegistry.new(tools_dir: @tools),
      transport: hub,
      request_ledger: ledger
    )
    @llm = CountingLLM.new
    d.instance_variable_set(:@llm, @llm)
    d.subscribe_topics

    payload = JSON.generate("request_id" => "wire-1", "prompt" => "write a greeting file")
    hub.publish("runes/prompts", payload)
    hub.publish("runes/prompts", payload)

    # The claim is synchronous, so the ledger already knows; the planner runs on
    # the worker pool, so wait for it before counting.
    # Prompts are claimed on the worker pool, not on the transport thread: the
    # claim has to live *after* the signature gate, or unverified traffic could
    # poison the ledger with someone else's request id. So wait for both
    # deliveries to be handled before counting.
    Timeout.timeout(10) { sleep 0.02 while ledger.claimed + ledger.duplicates < 2 }
    assert_equal 1, ledger.claimed, "the subscription path must claim, not just handle_prompt"
    assert_equal 1, ledger.duplicates
    Timeout.timeout(10) { sleep 0.02 while @llm.calls.zero? }
    sleep 0.2 # a wrongly queued second job would have landed by now
    assert_equal 1, @llm.calls, "a transport-level redelivery must run the planner once"
  end
end
