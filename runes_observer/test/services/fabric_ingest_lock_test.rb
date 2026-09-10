require "test_helper"
require "sqlite3"

# O5-3 reproduction, still valid after the ingest moved onto Runes::Transport:
# a second connection holds `BEGIN EXCLUSIVE` while the ingest tries to write.
# The old code called `IngestStatus.mark_disconnected!` (another write) from
# inside its rescue, which raised straight out of `run`.
#
# This is a plain Minitest::Test, not an ActiveSupport::TestCase: the
# transactional fixture wrapper would itself hold a write lock and a second
# connection could never take BEGIN EXCLUSIVE. Because it is NOT wrapped in a
# transaction, everything it writes is real: it must clean up after itself or
# the rows it creates leak into every later test (a page assertion that
# expects an empty packet log then sees this test's packet).
class FabricIngestLockTest < Minitest::Test
  REQUESTS = %w[locked-1 after-lock].freeze

  def teardown
    @ingest&.stop
    @thread&.join(5)
    @publisher&.disconnect
    Runes::Transport::InProcess.reset!
    Packet.where(request_id: REQUESTS).delete_all
    IngestStatus.delete_all
    PacketRecorder.reset_cache!
  end

  def test_ingest_survives_a_locked_database_and_recovers_when_it_clears
    # NOT `Packet.delete_all`: this test runs outside a transaction, so a
    # blanket delete would take the fixture rows every other test relies on
    # with it. It only ever owns the two requests below.
    locker = SQLite3::Database.new(ActiveRecord::Base.connection_db_config.database)
    locker.busy_timeout = 50
    locker.execute("BEGIN EXCLUSIVE")
    ActiveRecord::Base.connection.execute("PRAGMA busy_timeout = 50")

    @publisher = Runes::Transport::InProcess.new
    @publisher.connect
    @ingest = FabricIngest.new(transport_kind: "inproc", logger: Logger.new(IO::NULL),
                              poll_interval: 0.01)
    @thread = Thread.new { @ingest.run }
    # With the database locked the ingest cannot even write its own health
    # row, so wait on the transport it attached to and give the subscription
    # a moment to register.
    Timeout.timeout(10) { sleep 0.02 until @ingest.transport }
    sleep 0.1

    # While the lock is held every write fails, but the process must stay up.
    @publisher.publish("runes/prompts", JSON.generate("request_id" => "locked-1", "prompt" => "hi"))
    sleep 0.2
    assert @thread.alive?, "a locked database must not kill the ingest"

    locker.execute("COMMIT")
    locker.close
    ActiveRecord::Base.connection.execute("PRAGMA busy_timeout = 5000")

    @publisher.publish("runes/prompts", JSON.generate("request_id" => "after-lock", "prompt" => "hi"))
    Timeout.timeout(10) do
      sleep 0.05 until Packet.where(request_id: "after-lock").exists?
    end

    assert @thread.alive?
  end
end
