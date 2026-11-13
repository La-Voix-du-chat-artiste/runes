require "test_helper"

class ConnectorManagerTest < ActiveSupport::TestCase
  setup do
    Connector.delete_all
  end

  test "active_settings is nil with no active connector — env fallback stays in charge" do
    assert_nil ConnectorManager.active_settings
    Connector.create!(name: "inactive", host: "10.0.0.1", port: 1883, transport: "mqtt5", active: false)
    assert_nil ConnectorManager.active_settings
  end

  test "active_settings comes from the active row, password resolved from its env var" do
    ENV["TEST_CONNECTOR_PW"] = "s3cret"
    Connector.create!(name: "prod", host: "broker.example", port: 8883, transport: "mqtt5",
                      tls: true, username: "observer", password_env: "TEST_CONNECTOR_PW", active: true)

    settings = ConnectorManager.active_settings
    assert_equal "broker.example", settings[:host]
    assert_equal 8883, settings[:port]
    assert_equal "mqtt5", settings[:kind]
    assert_equal true, settings[:tls]
    assert_equal "observer", settings[:username]
    assert_equal "s3cret", settings[:password]
  ensure
    ENV.delete("TEST_CONNECTOR_PW")
  end

  test "activate! flips the active row and bumps the epoch exactly once per activation" do
    a = Connector.create!(name: "a", host: "h1", port: 1883, transport: "inproc")
    b = Connector.create!(name: "b", host: "h2", port: 1884, transport: "inproc")

    epoch0 = IngestStatus.current.connector_epoch
    ConnectorManager.activate!(a)
    assert a.reload.active?
    assert_equal epoch0 + 1, IngestStatus.current.connector_epoch

    ConnectorManager.activate!(b)
    assert_not a.reload.active?
    assert b.reload.active?
    assert_equal epoch0 + 2, IngestStatus.current.connector_epoch
    assert_equal 1, Connector.active.count
  end

  test "probe against an inproc hub reads retained agent cards" do
    # Seed a retained card on the default inproc hub.
    seeder = Runes::Transport.build(kind: "inproc")
    seeder.connect
    seeder.publish("$a2a/v1/discovery/org/unit/agent-1",
                   JSON.generate("name" => "agent-1"), retain: true)

    connector = Connector.create!(name: "local", host: "inproc", port: 1883, transport: "inproc")
    result = ConnectorManager.probe(connector, seconds: 0.3)

    assert_equal "ok", result[:state]
    assert_operator result[:cards], :>=, 1
    assert_equal "ok", connector.reload.last_probe_state
    assert connector.last_probe_at.present?
  ensure
    seeder&.disconnect
  end

  test "probe failure is recorded on the row, not raised" do
    connector = Connector.create!(name: "dead", host: "127.0.0.1", port: 1, transport: "mqtt5")
    result = ConnectorManager.probe(connector, seconds: 0.2)

    assert_equal "error", result[:state]
    assert_equal "error", connector.reload.last_probe_state
    assert_match /./, connector.last_probe_detail
  end
end
