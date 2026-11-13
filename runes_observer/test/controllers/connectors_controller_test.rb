require "test_helper"

# Workspace slice 2B: connector CRUD plus the two operator actions — probe
# and activate (which bumps the epoch the ingest polls).
class ConnectorsControllerTest < ActionDispatch::IntegrationTest
  setup do
    Connector.delete_all
  end

  test "index explains the env fallback when no profile exists" do
    get connectors_path

    assert_response :success
    assert_match "Connectors", response.body
    assert_match "RUNES_MQTT_HOST", response.body
    assert_match "New connector", response.body
  end

  test "create, update and destroy a connector" do
    assert_difference "Connector.count", 1 do
      post connectors_path, params: { connector: { name: "local", host: "127.0.0.1", port: 1883, transport: "mqtt5" } }
    end
    assert_redirected_to connectors_path

    connector = Connector.last
    patch connector_path(connector), params: { connector: { host: "10.0.0.2" } }
    assert_equal "10.0.0.2", connector.reload.host

    assert_difference "Connector.count", -1 do
      delete connector_path(connector)
    end
  end

  test "create with invalid params re-renders the form" do
    assert_no_difference "Connector.count" do
      post connectors_path, params: { connector: { name: "", host: "", port: 0, transport: "nope" } }
    end
    assert_response :unprocessable_entity
  end

  test "activate flips the active row and bumps the epoch" do
    a = Connector.create!(name: "a", host: "h1", port: 1883, transport: "inproc")
    b = Connector.create!(name: "b", host: "h2", port: 1884, transport: "inproc")
    epoch0 = IngestStatus.current.connector_epoch

    post activate_connector_path(b)

    assert_redirected_to connectors_path
    assert b.reload.active?
    assert_not a.reload.active?
    assert_equal epoch0 + 1, IngestStatus.current.connector_epoch
    assert_match "active connector", flash[:notice]
  end

  test "test probes the connector and reports the result" do
    connector = Connector.create!(name: "local", host: "inproc", port: 1883, transport: "inproc")
    old = ENV["RUNES_CONNECTOR_PROBE_SECONDS"]
    ENV["RUNES_CONNECTOR_PROBE_SECONDS"] = "0.3"

    post test_connector_path(connector)

    assert_redirected_to connectors_path
    assert_match(/retained agent card|probe failed/, flash[:notice].presence || flash[:alert].to_s)
    assert connector.reload.last_probe_at.present?
  ensure
    ENV["RUNES_CONNECTOR_PROBE_SECONDS"] = old
  end

  test "index shows the active badge and probe state" do
    Connector.create!(name: "prod", host: "broker", port: 8883, transport: "mqtt5", active: true,
                      last_probe_at: Time.current, last_probe_state: "ok",
                      last_probe_detail: "3 cards")

    get connectors_path

    assert_response :success
    assert_match "prod", response.body
    assert_match "active", response.body
    assert_match "broker:8883", response.body
    assert_match "ok", response.body
  end
end
