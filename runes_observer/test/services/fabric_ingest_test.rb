require "test_helper"

# A transport that fails once and then behaves, so the reconnection path can
# be driven without waiting on a real broker outage.
class ScriptedTransport
  attr_reader :mode

  def initialize(mode)
    @mode = mode
  end

  def name = "Scripted"
  def describe = "Scripted(#{@mode})"
  def connect = self
  def connected? = @mode == :good
  def subscribe(_filter, &_block) = nil
  def disconnect = nil
end

# The ingest is driven end to end through a REAL `Runes::Transport::InProcess`
# hub: no broker, no ports, no fake client. Publishing on one transport and
# reading it on the ingest's own subscription is exactly what the mqtt5 path
# does over TCP, so these tests exercise the wiring that actually ships
# (doc5.md O0.1).
class FabricIngestTest < ActiveSupport::TestCase
  setup do
    Packet.delete_all
    Agent.delete_all
    IngestStatus.delete_all
    PacketRecorder.reset_cache!
    Runes::Transport::InProcess.reset!
  end

  teardown do
    @ingest&.stop
    @thread&.join(5)
    @publisher&.disconnect
    Runes::Transport::InProcess.reset!
  end

  test "a broker-free inproc ingest records what a publisher puts on the fabric" do
    start_ingest
    publish("runes/prompts", JSON.generate("request_id" => "inproc-1", "prompt" => "hi"))

    packet = wait_for_packet(request_id: "inproc-1")
    assert_equal "prompt", packet.kind
    assert_includes Packet.pluck(:topic), "runes/prompts"
    assert IngestStatus.current.connected?, "the ingest reports itself connected"
  end

  test "MQTT 5 properties reach the database, which the mqtt 0.7 client could never do" do
    start_ingest
    publish("runes/a2a/tasks/agent-7",
            JSON.generate("method" => "tasks/send", "params" => {}),
            properties: { response_topic: "runes/a2a/replies/9",
                          correlation_id: "corr-42",
                          user_properties: { "a2a-status" => "working", "trace-id" => "t-1" } },
            qos: 1)

    packet = wait_for_packet(correlation_id: "corr-42")
    assert_equal "runes/a2a/replies/9", packet.response_topic
    assert_equal({ "a2a-status" => "working", "trace-id" => "t-1" }, packet.user_properties_hash)
    assert_equal 1, packet.qos
    assert packet.transport_properties?
  end

  test "user properties are bounded per value and stay parseable" do
    start_ingest
    huge = "x" * 5_000
    publish("runes/a2a/tasks/agent-8", "{}", properties: { user_properties: { "blob" => huge } })

    packet = wait_for_packet(topic: "runes/a2a/tasks/agent-8")
    value = packet.user_properties_hash.fetch("blob")
    assert_equal PacketRecorder::USER_PROPERTY_VALUE_BYTES, value.bytesize
    refute_nil packet.user_properties_hash, "a truncated value must still be valid JSON"
  end

  test "one unstoreable message is counted and dropped, and the good one still lands" do
    start_ingest
    original = PacketRecorder.method(:record)
    PacketRecorder.define_singleton_method(:record) do |**kwargs|
      raise Encoding::UndefinedConversionError, "boom" if kwargs[:payload] == "explode"

      original.call(**kwargs)
    end
    begin
      publish("runes/tools/echo/response", "explode")
      publish("runes/prompts", JSON.generate("request_id" => "ok-1", "prompt" => "hi"))
      wait_for_packet(request_id: "ok-1")
    ensure
      PacketRecorder.define_singleton_method(:record, original)
    end

    assert_equal 1, IngestStatus.current.packets_dropped
    assert IngestStatus.current.connected?, "a bad message must not disconnect the ingest"
  end

  test "a non-UTF-8 payload does not tear down the subscription" do
    start_ingest
    publish("runes/tools/echo/response", "\xff\xfe".b)
    publish("runes/prompts", JSON.generate("request_id" => "ok-2", "prompt" => "hi"))

    wait_for_packet(request_id: "ok-2")
    assert_equal 0, IngestStatus.current.packets_dropped
    assert_includes Packet.pluck(:kind), "tool_response"
  end

  test "the transport's retain flag reaches the recorder" do
    Agent.record_status!("runes-retained", "online", at: 30.minutes.ago)
    start_publisher
    publish("runes/agents/runes-retained/card",
            JSON.generate("name" => "runes-retained"), retain: true)
    # Retained messages are replayed to whoever subscribes next — here, the
    # ingest — with the retain flag set.
    start_ingest

    wait_for_packet(topic: "runes/agents/runes-retained/card")
    assert Agent.find_by(agent_id: "runes-retained").stale?
    assert Packet.find_by(topic: "runes/agents/runes-retained/card").retain
  end

  test "a dead transport is rebuilt with backoff instead of hanging forever" do
    built = []
    factory = lambda do |**_kwargs|
      mode = built.any? ? :good : :dead
      built << mode
      ScriptedTransport.new(mode)
    end
    ingest = FabricIngest.new(logger: Logger.new(IO::NULL), transport_factory: factory,
                              poll_interval: 0.01, backoff: 0.01, disconnect_grace: 0.05)

    thread = Thread.new { ingest.run }
    Timeout.timeout(10) { sleep 0.02 until built.size >= 2 }
    assert_equal %i[dead good], built, "the first transport failed and a fresh one was built"
  ensure
    ingest&.stop
    thread&.join(5)
  end

  private

  def start_publisher
    @publisher = Runes::Transport::InProcess.new
    @publisher.connect
  end

  def start_ingest
    start_publisher unless @publisher
    # A fresh ingest gets its own inproc client on the same default hub.
    @ingest = FabricIngest.new(transport_kind: "inproc", logger: Logger.new(IO::NULL),
                               poll_interval: 0.01)
    @thread = Thread.new { @ingest.run }
    Timeout.timeout(10) { sleep 0.02 until IngestStatus.current.connected? }
  end

  def publish(topic, payload, properties: {}, qos: 0, retain: false)
    @publisher.publish(topic, payload, qos: qos, retain: retain, properties: properties)
  end

  def wait_for_packet(**conditions)
    packet = nil
    Timeout.timeout(10) do
      loop do
        packet = Packet.where(**conditions).recent.first
        break if packet

        sleep 0.02
      end
    end
    packet
  end
end

# Retention must not depend on traffic: the pruner thread is what makes it a
# property of the process (doc5.md O5-6).
class FabricIngestPrunerTest < ActiveSupport::TestCase
  def test_the_pruner_runs_without_any_traffic
    previous = ENV["RUNES_OBSERVER_PRUNE_INTERVAL_S"]
    ENV["RUNES_OBSERVER_PRUNE_INTERVAL_S"] = "0.05"

    stale = Packet.create!(topic: "runes/agents/old/card", kind: "card", payload: "{}",
                           occurred_at: 400.days.ago, received_at: 400.days.ago,
                           payload_bytes: 2)
    ingest = FabricIngest.new(transport_kind: "inproc", logger: Logger.new(File::NULL))

    ingest.start_pruner
    Timeout.timeout(10) do
      sleep 0.05 while Packet.exists?(stale.id)
    end

    refute Packet.exists?(stale.id), "an idle ingest must still prune old packets"
  ensure
    ingest&.stop_pruner
    if previous.nil?
      ENV.delete("RUNES_OBSERVER_PRUNE_INTERVAL_S")
    else
      ENV["RUNES_OBSERVER_PRUNE_INTERVAL_S"] = previous
    end
  end
end
