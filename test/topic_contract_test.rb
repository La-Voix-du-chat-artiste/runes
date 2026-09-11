# frozen_string_literal: true

require_relative "test_helper"

# The publisher/observer contract (doc5.md E5-2).
#
# The observatory's classifier is a COPY of the harness's topic grammar and
# nothing used to check the two against each other — which is how the
# claim/lease vocabulary survived a protocol deletion for a whole release and
# left the observer modelling traffic nothing publishes. This test closes that
# in both directions:
#
#   1. every topic a REAL dispatcher publishes must classify to a known kind
#      (no silent `other`), and
#   2. every pattern the classifier defines must have a representative topic
#      here, so a new pattern cannot be added without a producer to justify it.
class TopicContractTest < Minitest::Test
  # The observer's classifier is a plain module (JSON only), so the parent
  # suite can load it directly. Requiring it here is the point: this test is
  # the only place the two halves meet.
  require_relative "../runes_observer/app/services/packet_classifier"

  # One topic per pattern the classifier knows. Adding a pattern without a
  # representative here fails `test_every_classifier_pattern_has_a_representative`.
  REPRESENTATIVE = {
    "AGENT_CARD" => ["runes/agents/runes-a/card", "card"],
    "AGENT_STATUS" => ["runes/agents/runes-a/status", "status"],
    "AGENT_TASKS" => ["runes/agents/runes-a/tasks", "task"],
    "TASK_REPLY" => ["runes/agents/runes-a/tasks/r1/response", "task_response"],
    "PROMPT" => ["runes/prompts", "prompt"],
    "GLOBAL_RESPONSE" => ["runes/prompts/response", "response_global"],
    "PROMPT_PROGRESS" => ["runes/prompts/r1/progress", "progress"],
    "PROMPT_RESPONSE" => ["runes/prompts/r1/response", "response"],
    "TOOL" => ["runes/tools/read_file/request", "tool_request"],
    "JOURNAL" => ["runes/_log/prompts", "journal"],
    "GUARD" => ["runes/guard/denied", "guard_denied"],
    "WORKFLOW" => ["runes/workflows/abc123/step_finished", "workflow_event"],
    "A2A_CARD" => ["$a2a/v1/discovery/runes/host/runes-a", "a2a_card"],
    "A2A_TASK" => ["$a2a/v1/tasks/runes/host/runes-a", "a2a_task"]
  }.freeze

  # A planner that reports one safe builtin: no subprocess, no network.
  class WritingLLM
    def call(_prompt, **_options)
      { ok: true, mode: :tool_calls, raw: {},
        tool_calls: [{ tool: "write_file",
                       args: { "path" => "contract.txt", "content" => "written by the contract test" } }] }
    end
  end

  def setup
    @tmp = Dir.mktmpdir("runes-contract-")
    @tools = Dir.mktmpdir("runes-contract-tools-")
    @settings = Runes::Core::Settings.new(root: @tmp)
    @transport = RecordingTransport.new
    # Only the workspace is overridden, and it is restored below. RUNES_ROOT
    # belongs to test_helper and is process-global: overwriting it here leaked
    # into unrelated tests (11 errors) because the directory is deleted in
    # teardown. `Settings.new(root:)` already scopes this dispatcher.
    ENV["RUNES_WORKSPACE"] = File.join(@tmp, "workspace")
  end

  def teardown
    [@tmp, @tools].each { |dir| FileUtils.remove_entry(dir) if dir && Dir.exist?(dir) }
    ENV.delete("RUNES_WORKSPACE")
  end

  def dispatcher(agent_id: "contract-agent")
    d = Runes::Core::Dispatcher.new(
      { host: "127.0.0.1", port: 0 }, nil, nil,
      settings: @settings, agent_id: agent_id,
      tool_registry: Runes::Core::ToolRegistry.new(tools_dir: @tools),
      transport: @transport
    )
    d.instance_variable_set(:@llm, WritingLLM.new)
    d
  end

  def topics
    @transport.published.map { |message| message[:topic] }
  end

  def classifications
    @transport.published.map do |message|
      [message[:topic], PacketClassifier.call(topic: message[:topic], payload: message[:payload])]
    end
  end

  # --- direction 1: everything a real dispatcher publishes is understood ---

  def test_every_topic_a_dispatcher_publishes_classifies_to_a_known_kind
    d = dispatcher
    d.announce_agent_card
    d.subscribe_topics
    d.handle_payload("write a file please")
    d.delegate_to(@transport, "runes-peer", "do this instead", request_id: "req1234")

    refute_empty topics, "the dispatcher must actually publish something for this to mean anything"

    unknown = classifications.select { |_topic, result| result.kind == "other" }
    assert_empty unknown.map(&:first),
                 "the observer classifies these as `other`, so it is missing a producer: #{unknown.inspect}"
    classifications.each do |topic, result|
      assert_includes PacketClassifier::KINDS, result.kind,
                      "#{topic} classified as #{result.kind}, which Packet::KINDS rejects"
    end
  end

  # Note what is NOT here: `runes/prompts` is published by the CLIENT
  # (bin/runes-client, the TUI), not by an agent — a dispatcher only subscribes
  # to it. That side of the grammar is covered by the representative table
  # below, which is why the table exists as well as this test.
  def test_the_paths_a_prompt_takes_are_all_observed
    d = dispatcher
    d.handle_payload("write a file please", reply_topic: "runes/prompts/req-abc/response")

    kinds = classifications.map { |_topic, result| result.kind }.uniq.sort
    assert_includes kinds, "progress", "a build publishes progress"
    assert_includes kinds, "response", "the correlated reply"
    assert_includes kinds, "journal", "every prompt lifecycle is journalled"
  end

  def test_a_prompt_without_a_correlated_reply_uses_the_global_topic
    dispatcher.handle_payload("write a file please")

    kinds = classifications.map { |_topic, result| result.kind }.uniq.sort
    assert_includes kinds, "response_global"
  end

  def test_a_delegation_is_observed_as_a_task_and_names_both_ends
    d = dispatcher(agent_id: "runes-lead")
    d.delegate_to(@transport, "runes-peer", "do this", request_id: "req5678")

    message = @transport.published.find { |m| m[:topic] == "runes/agents/runes-peer/tasks" }
    refute_nil message, "a delegation goes to the peer's tasks topic"
    result = PacketClassifier.call(topic: message[:topic], payload: message[:payload])
    assert_equal "task", result.kind
    assert_equal "runes-peer", result.agent_id, "the topic names the target"
    assert_equal "req5678", result.request_id
    # ...and the payload names the delegator, which is what the topology view
    # draws the edge from.
    assert_equal "runes-lead", JSON.parse(message[:payload])["from"]
  end

  def test_the_card_and_status_topics_are_observed
    dispatcher.announce_agent_card

    card = classifications.find { |topic, _| topic.end_with?("/card") }
    status = classifications.find { |topic, _| topic.end_with?("/status") }
    assert_equal "card", card.last.kind
    assert_equal "status", status.last.kind
  end

  # --- direction 2: no pattern without a producer -------------------------

  def test_every_classifier_pattern_has_a_representative
    patterns = PacketClassifier.constants.grep(/RE|\A[A-Z_]+\z/).select do |name|
      value = PacketClassifier.const_get(name)
      value.is_a?(Regexp) || value.is_a?(String)
    end

    missing = patterns.map(&:to_s) - REPRESENTATIVE.keys
    assert_empty missing.sort,
                 "these classifier patterns have no representative topic, so nothing proves a producer exists: #{missing.inspect}"
  end

  def test_every_representative_classifies_to_its_expected_kind
    REPRESENTATIVE.each do |pattern, (topic, expected)|
      result = PacketClassifier.call(topic: topic, payload: "{}")
      assert_equal expected, result.kind, "#{pattern} representative #{topic}"
    end
  end
end
