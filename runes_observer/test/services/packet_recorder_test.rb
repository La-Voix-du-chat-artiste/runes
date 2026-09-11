require "test_helper"

# The recorder is the single write path for the observer: live ingest and
# the demo seeder both go through it, so these tests cover both. The
# attribution tests replay the shapes the Phase 17 dispatcher actually
# publishes — never the claim/lease protocol deleted in Phase 16.
class PacketRecorderTest < ActiveSupport::TestCase
  setup do
    # These tests assert absolute row counts; drop the packet fixtures.
    Packet.delete_all
    Agent.delete_all
  end

  test "a card creates the agent but leaves the state unknown" do
    PacketRecorder.record(
      topic: "runes/agents/runes-new/card",
      payload: JSON.generate("name" => "runes-new", "kind" => "runes.dispatcher",
                             "tools" => %w[read_file], "workspace" => "/tmp/ws")
    )

    agent = Agent.find_by(agent_id: "runes-new")
    assert_not_nil agent
    assert_equal "unknown", agent.state
    assert_equal %w[read_file], agent.tools_list
    assert_equal "card", Packet.last.kind
  end

  # The A2A discovery card is A2A-shaped: its Runes facts live under
  # `x-runes`. The recorder hands the parsed payload straight to
  # Agent.record_card!, so PacketClassifier.parse is where the shapes are
  # reconciled (see normalize_card). Once PacketRecorder dispatches
  # `a2a_card` to the card path, an A2A card populates the row exactly like
  # a legacy one.
  test "an A2A-shaped card populates the agent row through the card path" do
    payload = JSON.generate(
      "protocolVersion" => "0.3.0",
      "name" => "runes-abc123",
      "version" => "1.2.3",
      "skills" => [{ "id" => "read_file" }],
      "x-runes" => { "kind" => "runes.dispatcher", "workspace" => "/tmp/a2a-ws",
                     "tools" => %w[read_file echo] }
    )

    Agent.record_card!("runes-abc123", PacketClassifier.parse(payload))

    agent = Agent.find_by(agent_id: "runes-abc123")
    assert_equal "unknown", agent.state, "a retained card must not flip the state"
    assert_equal "runes-abc123", agent.name
    assert_equal "runes.dispatcher", agent.kind
    assert_equal "1.2.3", agent.version
    assert_equal "/tmp/a2a-ws", agent.workspace
    assert_equal %w[read_file echo], agent.tools_list
  end

  test "status packets drive online, offline and ended_at" do
    PacketRecorder.record(topic: "runes/agents/runes-new/status", payload: "online")
    assert Agent.find_by(agent_id: "runes-new").online?

    PacketRecorder.record(topic: "runes/agents/runes-new/status", payload: "offline")
    agent = Agent.find_by(agent_id: "runes-new")
    assert agent.ended?
    assert_not_nil agent.ended_at
  end

  test "an envelope that names its executor is attributed directly" do
    packet = PacketRecorder.record(topic: "runes/prompts/r-88/progress",
                                   payload: JSON.generate("event" => "plan_ready",
                                                          "from" => "runes-sender"))

    assert_equal "runes-sender", packet.agent_id
    assert_equal "r-88", packet.request_id
    assert_equal "runes-sender", Agent.find_by(agent_id: "runes-sender").agent_id
  end

  # O5-5 regression: replaying the REAL shapes (prompt, progress, response,
  # then the trailing journal entry) must attribute every row of the request.
  test "the journal entry backfills agent attribution for the whole request" do
    record = ->(topic, payload) { PacketRecorder.record(topic: topic, payload: payload) }

    record.call("runes/prompts", JSON.generate("request_id" => "x1", "prompt" => "hi",
                                               "mode" => "build"))
    record.call("runes/prompts/x1/progress", JSON.generate("event" => "plan_ready"))
    record.call("runes/prompts/x1/response", "done")
    record.call("runes/_log/prompts",
                JSON.generate("request_id" => "x1", "agent" => "runes-a",
                              "status" => "complete", "summary" => "done"))

    rows = Packet.for_request("x1")
    assert_equal 4, rows.count
    assert_equal 4, rows.where.not(agent_id: nil).count
    assert_equal ["runes-a"], rows.distinct.pluck(:agent_id)
  end

  test "attribution survives across processes of the same request" do
    journal = PacketRecorder.record(topic: "runes/_log/prompts",
                                    payload: JSON.generate("request_id" => "r-77", "agent" => "runes-alpha"))
    # Clear the in-process memo to force the DB lookup path.
    PacketRecorder.reset_cache!
    packet = PacketRecorder.record(topic: "runes/prompts/r-77/progress",
                                   payload: JSON.generate("event" => "step_end"))
    assert_equal "runes-alpha", packet.agent_id
    assert_equal journal.request_id, packet.request_id
  end

  test "the agent packet counter follows card and status packets too" do
    PacketRecorder.record(topic: "runes/agents/runes-count/card",
                          payload: JSON.generate("name" => "runes-count"))
    PacketRecorder.record(topic: "runes/agents/runes-count/status", payload: "online")

    agent = Agent.find_by(agent_id: "runes-count")
    assert_equal 2, agent.packet_count
  end

  test "oversized payloads are truncated but their real size is kept" do
    huge = "x" * (Packet::MAX_PAYLOAD_BYTES + 10)
    PacketRecorder.record(topic: "runes/tools/echo/response", payload: huge)

    packet = Packet.recent.first
    assert packet.truncated
    refute packet.scrubbed
    assert_equal Packet::MAX_PAYLOAD_BYTES, packet.payload.bytesize
    assert_equal huge.bytesize, packet.payload_bytes
  end

  # O5-1 regression: a non-UTF-8 payload used to reach the sqlite3 bind as
  # ASCII-8BIT and raise Encoding::UndefinedConversionError, wedging ingest.
  test "a small non-UTF-8 payload is scrubbed and stored" do
    packet = PacketRecorder.record(topic: "runes/agents/runes-bin/status",
                                   payload: "\xC3\x28".b)

    assert packet.scrubbed
    assert packet.payload.valid_encoding?
    assert_includes packet.payload, "\uFFFD"
    assert_equal "\xC3\x28".bytesize, packet.payload_bytes
  end

  test "a large non-UTF-8 payload is scrubbed, bounded and stored" do
    payload = ("\xff".b * (Packet::MAX_PAYLOAD_BYTES + 10))
    packet = PacketRecorder.record(topic: "runes/tools/echo/response", payload: payload)

    assert packet.scrubbed
    assert packet.truncated
    assert packet.payload.valid_encoding?
    assert_operator packet.payload.bytesize, :<=, Packet::MAX_PAYLOAD_BYTES
    assert_equal payload.bytesize, packet.payload_bytes
  end

  # O5-6 regression: a retained card replay used to set last_seen_at = now,
  # so a dead agent never stayed stale.
  test "a retained card or status replay does not resurrect a dead agent" do
    Agent.record_status!("runes-dead", "online", at: 30.minutes.ago)
    assert Agent.find_by(agent_id: "runes-dead").stale?

    PacketRecorder.record(topic: "runes/agents/runes-dead/card",
                          payload: JSON.generate("name" => "runes-dead"), retained: true)
    PacketRecorder.record(topic: "runes/agents/runes-dead/status",
                          payload: "online", retained: true)

    agent = Agent.find_by(agent_id: "runes-dead")
    assert agent.stale?, "a retained replay must not refresh the clock"
    assert_operator agent.last_seen_at, :<, 25.minutes.ago
  end

  test "a live (non-retained) card replay still refreshes the clock" do
    Agent.record_status!("runes-live", "online", at: 30.minutes.ago)

    PacketRecorder.record(topic: "runes/agents/runes-live/card",
                          payload: JSON.generate("name" => "runes-live"))

    refute Agent.find_by(agent_id: "runes-live").stale?
  end

  test "four retained replays after SUBSCRIBE store one card" do
    4.times do
      PacketRecorder.begin_session!
      PacketRecorder.record(topic: "runes/agents/runes-dup/card",
                            payload: JSON.generate("name" => "runes-dup"))
    end

    assert_equal 1, Packet.of_kind("card").count
  end

  test "dedupe does not merge genuinely different packets" do
    PacketRecorder.begin_session!
    PacketRecorder.record(topic: "runes/agents/runes-a/card", payload: JSON.generate("name" => "runes-a"))
    PacketRecorder.record(topic: "runes/agents/runes-b/card", payload: JSON.generate("name" => "runes-b"))

    assert_equal 2, Packet.of_kind("card").count
  end

  test "the ingest heartbeat is recorded" do
    PacketRecorder.record(topic: "runes/prompts",
                          payload: JSON.generate("request_id" => "r1", "prompt" => "hi"))

    status = IngestStatus.current
    assert_not_nil status.last_message_at
    assert_operator status.packets_total, :>=, 1
  end

  test "prune! drops packets older than the retention window" do
    old = PacketRecorder.record(topic: "runes/prompts", payload: "{}", occurred_at: 30.days.ago)
    recent = PacketRecorder.record(topic: "runes/prompts", payload: "{}", occurred_at: Time.current)

    PacketRecorder.prune!(days: 7)

    assert_nil Packet.find_by(id: old.id)
    assert_not_nil Packet.find_by(id: recent.id)
  end

  test "prune! caps the table when max is positive" do
    6.times { |i| PacketRecorder.record(topic: "runes/prompts", payload: JSON.generate("request_id" => "p#{i}")) }
    newest = Packet.order(:id).last(4).map(&:id)

    PacketRecorder.prune!(days: 7, max: 4)

    assert_equal newest, Packet.order(:id).pluck(:id)
  end

  test "MAX_PACKETS=0 means no cap, not truncate the whole table" do
    3.times { |i| PacketRecorder.record(topic: "runes/prompts", payload: JSON.generate("request_id" => "c#{i}")) }

    with_env("RUNES_OBSERVER_MAX_PACKETS", "0") do
      assert_nil PacketRecorder.max_packets
      PacketRecorder.prune!(days: 7)
    end

    assert_equal 3, Packet.count
  end

  test "a non-numeric MAX_PACKETS warns and means no cap" do
    with_env("RUNES_OBSERVER_MAX_PACKETS", "lots") do
      assert_nil PacketRecorder.max_packets
    end
  end

  private

  def with_env(key, value)
    previous = ENV[key]
    ENV[key] = value
    yield
  ensure
    previous.nil? ? ENV.delete(key) : ENV[key] = previous
  end
  # doc5.md O0.5: `occurred_at` used to be nothing but our receipt time, which
  # made a packet's real age unknowable and an ingest lag figure impossible.
  # The journal writes `at`, a signed envelope carries `ts`; both are believed
  # only when plausible.
  test "a payload's own clock becomes occurred_at and drives the lag figure" do
    sent_at = 5.seconds.ago
    PacketRecorder.record(topic: "runes/_log/prompts",
                          payload: JSON.generate("request_id" => "clock-1", "agent" => "a1",
                                                 "status" => "complete", "at" => sent_at.utc.iso8601))

    packet = Packet.find_by(request_id: "clock-1")
    assert_in_delta sent_at.to_f, packet.occurred_at.to_f, 1.0
    assert_operator packet.received_at, :>=, packet.occurred_at
    assert_in_delta 5_000, IngestStatus.current.last_lag_ms, 1_500
  end

  test "an envelope's unix ts is honoured too" do
    PacketRecorder.record(topic: "runes/prompts",
                          payload: JSON.generate("request_id" => "clock-2", "prompt" => "hi",
                                                 "ts" => 10.seconds.ago.to_i))

    assert_in_delta 10.seconds.ago.to_f, Packet.find_by(request_id: "clock-2").occurred_at.to_f, 1.0
  end

  test "an implausible clock is ignored rather than reordering the timeline" do
    future = (Time.current + 1.hour).utc.iso8601
    ancient = (Time.current - 30.days).utc.iso8601

    PacketRecorder.record(topic: "runes/_log/prompts",
                          payload: JSON.generate("request_id" => "clock-future", "status" => "x", "at" => future))
    PacketRecorder.record(topic: "runes/_log/prompts",
                          payload: JSON.generate("request_id" => "clock-ancient", "status" => "x", "at" => ancient))

    assert_in_delta Time.current.to_f, Packet.find_by(request_id: "clock-future").occurred_at.to_f, 5
    assert_in_delta Time.current.to_f, Packet.find_by(request_id: "clock-ancient").occurred_at.to_f, 5
  end

  test "no clock in the payload leaves occurred_at as the receipt time" do
    PacketRecorder.record(topic: "runes/prompts",
                          payload: JSON.generate("request_id" => "clock-none", "prompt" => "hi"))

    packet = Packet.find_by(request_id: "clock-none")
    assert_in_delta packet.received_at.to_f, packet.occurred_at.to_f, 0.01
    assert_nil IngestStatus.current.last_lag_ms, "unknown lag must not be recorded as zero"
  end
end
