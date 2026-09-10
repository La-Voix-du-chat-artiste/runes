require "test_helper"

class IngestStatusTest < ActiveSupport::TestCase
  test "current is a singleton row" do
    first = IngestStatus.current
    second = IngestStatus.current

    assert_equal first.id, second.id
    assert_equal 1, IngestStatus.count
  end

  test "connect / heartbeat / disconnect drive the display state" do
    IngestStatus.mark_connected!(host: "127.0.0.1", port: 1883)
    status = IngestStatus.current
    assert status.connected?
    assert_equal 1883, status.port
    assert_equal "connected", status.display_state, "connected but silent"

    IngestStatus.bump!(at: Time.current, by: 3)
    status = IngestStatus.current
    assert status.watching?
    assert_equal "watching", status.display_state
    assert_equal 3, status.packets_total

    IngestStatus.mark_disconnected!("boom")
    status = IngestStatus.current
    refute status.connected?
    assert_equal "boom", status.last_error
    assert_equal "disconnected", status.display_state
  end

  test "never connected reads as no data" do
    assert_equal "no data", IngestStatus.current.display_state
  end

  # O5-6: a killed ingest leaves the row `connected` forever; the age of the
  # last sign of life must surface it as dead instead.
  test "a connected but silent ingest reads as dead" do
    IngestStatus.mark_connected!(host: "127.0.0.1", port: 1883)
    IngestStatus.bump!(at: 10.minutes.ago, by: 1)

    status = IngestStatus.current
    assert status.dead?
    assert_equal "dead", status.display_state
  end

  test "a fresh connection is not dead" do
    IngestStatus.mark_connected!(host: "127.0.0.1", port: 1883)

    refute IngestStatus.current.dead?
  end

  test "dropped packets are counted" do
    IngestStatus.mark_connected!(host: "127.0.0.1", port: 1883)
    IngestStatus.bump_dropped!
    IngestStatus.bump_dropped!(by: 2)

    assert_equal 3, IngestStatus.current.packets_dropped
  end

  # O5-3: the writers are called from the ingest's rescue/ensure path, so
  # they must never raise. Simulate every write failing.
  test "status writers swallow and log their own failures" do
    original = IngestStatus.method(:current)
    failing = ->(*) { raise ActiveRecord::StatementInvalid, "database is locked" }
    IngestStatus.define_singleton_method(:current, failing)
    begin
      assert_nil IngestStatus.mark_connected!(host: "127.0.0.1", port: 1883)
      assert_nil IngestStatus.mark_disconnected!("boom")
      assert_nil IngestStatus.bump!(at: Time.current, by: 1)
      assert_nil IngestStatus.bump_dropped!
    ensure
      IngestStatus.define_singleton_method(:current, original)
    end
  end
end
