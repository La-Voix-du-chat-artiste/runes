require "test_helper"

class ConnectorTest < ActiveSupport::TestCase
  test "valid connector" do
    assert Connector.new(name: "local", host: "127.0.0.1", port: 1883, transport: "mqtt5").valid?
  end

  test "name is required and unique, host required, port in range, transport whitelisted" do
    assert_not Connector.new(host: "h", port: 1883, transport: "auto").valid?
    Connector.create!(name: "dup", host: "h", port: 1883, transport: "auto")
    assert_not Connector.new(name: "dup", host: "h", port: 1883, transport: "auto").valid?
    assert_not Connector.new(name: "x", host: "", port: 1883, transport: "auto").valid?
    assert_not Connector.new(name: "x", host: "h", port: 0, transport: "auto").valid?
    assert_not Connector.new(name: "x", host: "h", port: 70_000, transport: "auto").valid?
    assert_not Connector.new(name: "x", host: "h", port: 1883, transport: "carrier-pigeon").valid?
  end

  test "probe_label" do
    c = Connector.new(name: "x", host: "h", port: 1, transport: "auto")
    assert_equal "never probed", c.probe_label
    c.last_probe_at = Time.current
    c.last_probe_state = "ok"
    assert_match "ok", c.probe_label
  end
end
