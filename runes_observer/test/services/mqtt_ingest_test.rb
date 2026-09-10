require "test_helper"

# The consume loop must isolate a single bad message: the old code let the
# exception escape, the broker replayed every retained message, and ingest
# spun forever re-inserting them (O5-1).
class MqttIngestTest < ActiveSupport::TestCase
  FakePacket = Struct.new(:topic, :payload, :retain, keyword_init: true)

  class FakeClient
    attr_reader :connects

    def initialize(messages, on_exhausted:)
      @messages = messages
      @on_exhausted = on_exhausted
      @connects = 0
    end

    def connect; @connects += 1; end
    def subscribe(_topics); end

    def get_packet
      message = @messages.shift
      return message if message

      @on_exhausted.call
      nil
    end

    def disconnect; end
  end

  setup do
    Packet.delete_all
    Agent.delete_all
  end

  test "one failing message is counted and dropped, and the good one still lands" do
    bad = FakePacket.new(topic: "runes/tools/echo/response", payload: "explode", retain: false)
    good = FakePacket.new(topic: "runes/prompts",
                          payload: JSON.generate("request_id" => "ok-1", "prompt" => "hi"), retain: false)
    ingest, clients = build_ingest([bad, good])

    original = PacketRecorder.method(:record)
    PacketRecorder.define_singleton_method(:record) do |**kwargs|
      raise Encoding::UndefinedConversionError, "boom" if kwargs[:payload] == "explode"

      original.call(**kwargs)
    end
    begin
      ingest.run
    ensure
      PacketRecorder.define_singleton_method(:record, original)
    end

    assert_equal 1, clients.size, "a bad message must not cause a reconnect"
    assert_equal 1, clients.first.connects
    assert_equal 1, Packet.where(request_id: "ok-1").count, "the good message still lands"
    assert_equal 1, IngestStatus.current.packets_dropped
  end

  test "a non-UTF-8 payload does not tear down the connection" do
    invalid = FakePacket.new(topic: "runes/tools/echo/response", payload: "\xff\xfe".b, retain: false)
    good = FakePacket.new(topic: "runes/prompts",
                          payload: JSON.generate("request_id" => "ok-2", "prompt" => "hi"), retain: false)
    ingest, clients = build_ingest([invalid, good])

    ingest.run

    assert_equal 1, clients.size
    assert_equal 1, clients.first.connects
    assert_equal 2, Packet.count
    assert_includes Packet.pluck(:kind), "tool_response"
    assert_equal 0, IngestStatus.current.packets_dropped
  end

  test "the transport's retain flag reaches the recorder" do
    Agent.record_status!("runes-retained", "online", at: 30.minutes.ago)
    card = FakePacket.new(topic: "runes/agents/runes-retained/card",
                          payload: JSON.generate("name" => "runes-retained"), retain: true)
    ingest, = build_ingest([card])

    ingest.run

    assert Agent.find_by(agent_id: "runes-retained").stale?
  end

  private

  def build_ingest(messages)
    clients = []
    ingest = nil
    factory = lambda do |host:, port:, client_id:|
      client = FakeClient.new(messages, on_exhausted: -> { ingest.stop })
      clients << client
      client
    end
    ingest = MqttIngest.new(host: "127.0.0.1", port: 1883,
                            logger: Logger.new(IO::NULL), client_factory: factory)
    [ingest, clients]
  end
end
