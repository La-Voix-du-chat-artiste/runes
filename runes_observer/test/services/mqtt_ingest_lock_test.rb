require "test_helper"
require "sqlite3"

# O5-3 reproduction: a second connection holds `BEGIN EXCLUSIVE` while the
# ingest tries to write. The old code called `IngestStatus.mark_disconnected!`
# (another write) from inside its rescue, which raised straight out of `run`.
#
# This is a plain Minitest::Test, not an ActiveSupport::TestCase: the
# transactional fixture wrapper would itself hold a write lock and a second
# connection could never take BEGIN EXCLUSIVE.
class MqttIngestLockTest < Minitest::Test
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

  def test_ingest_survives_a_locked_database
    locker = nil
    connection = nil
    db_path = ActiveRecord::Base.connection_db_config.database

    locker = SQLite3::Database.new(db_path)
    locker.busy_timeout = 50
    locker.execute("BEGIN EXCLUSIVE")

    connection = ActiveRecord::Base.connection
    connection.execute("PRAGMA busy_timeout = 50")

    good = FakePacket.new(topic: "runes/prompts",
                          payload: JSON.generate("request_id" => "locked-1", "prompt" => "hi"),
                          retain: false)
    clients = []
    ingest = nil
    factory = lambda do |host:, port:, client_id:|
      client = FakeClient.new([good], on_exhausted: -> { ingest.stop })
      clients << client
      client
    end
    ingest = MqttIngest.new(host: "127.0.0.1", port: 1883,
                            logger: Logger.new(IO::NULL), client_factory: factory)

    # Sanity: the lock really is held, so a plain record raises.
    assert_raises(StandardError) do
      PacketRecorder.record(topic: "runes/prompts", payload: "{}")
    end

    # The ingest must ride the failure out rather than die in its own rescue.
    assert_nil ingest.run, "run returned instead of raising out of the locked DB"
    assert_equal 1, clients.size, "the locked DB must not force a reconnect"
  ensure
    # This test is not wrapped in a transaction, so it must never delete
    # rows: the committed fixtures are shared with every other test in the
    # process, and an un-rolled-back `delete_all` would wipe them.
    locker&.execute("ROLLBACK")
    locker&.close
    connection&.execute("PRAGMA busy_timeout = 5000")
  end
end
