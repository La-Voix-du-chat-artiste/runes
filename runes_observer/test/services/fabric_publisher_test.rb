require "test_helper"

# The web process's best-effort publisher: one lazy transport, publishes
# through it, and never raises — a missing broker returns false.
class FabricPublisherTest < ActiveSupport::TestCase
  setup do
    @old_transport = ENV["RUNES_TRANSPORT"]
    @old_publish = ENV["RUNES_OBSERVER_PUBLISH"]
    ENV["RUNES_TRANSPORT"] = "inproc"
    ENV["RUNES_OBSERVER_PUBLISH"] = "on"
    FabricPublisher.reset!
  end

  teardown do
    FabricPublisher.reset!
    ENV["RUNES_TRANSPORT"] = @old_transport
    ENV["RUNES_OBSERVER_PUBLISH"] = @old_publish
  end

  test "publish delivers to an inproc subscriber in the same process" do
    received = Queue.new
    listener = Runes::Transport.build(kind: "inproc")
    listener.connect
    listener.subscribe("runes/docs/added") { |msg| received << msg.payload }

    assert FabricPublisher.publish("runes/docs/added", { "sha" => "a" * 64 })

    payload = JSON.parse(received.pop)
    assert_equal "a" * 64, payload["sha"]
  ensure
    listener.disconnect
  end

  test "publish is a no-op when disabled" do
    ENV["RUNES_OBSERVER_PUBLISH"] = "off"
    assert_not FabricPublisher.enabled?
    assert_not FabricPublisher.publish("runes/docs/added", {})
  end

  test "a failing transport returns false and drops the connection, never raises" do
    # Point at a port nothing listens on with mqtt5 forced: connect fails.
    ENV["RUNES_TRANSPORT"] = "mqtt5"
    ENV["RUNES_MQTT_PORT"] = "1"
    FabricPublisher.reset!

    assert_not FabricPublisher.publish("runes/docs/added", {})
  ensure
    ENV.delete("RUNES_MQTT_PORT")
  end
end
