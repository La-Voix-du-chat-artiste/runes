require "test_helper"

class AlertsControllerTest < ActionDispatch::IntegrationTest
  setup do
    Packet.delete_all
    Alert.delete_all
  end

  def test_index_lists_alerts_and_ack_clears_the_badge
    Alert.record(kind: "impersonation", subject: "writer", severity: "error")
    get alerts_path
    assert_response :success
    assert_select "td.mono", text: "impersonation"
    assert_select "td.mono", text: "writer"
    assert_select "button", text: "Ack"

    alert = Alert.first
    post ack_alert_path(alert)
    assert_redirected_to alerts_path
    assert alert.reload.acknowledged

    get alerts_path
    assert_response :success
    assert_select "button", text: "Ack", count: 0
    assert_select ".sub", text: "acked"
  end

  def test_index_runs_detectors_over_recent_packets
    payload = JSON.generate("agent_id" => "writer")
    2.times do |i|
      Packet.create!(topic: "runes/prompts", payload: payload, kind: "prompt", agent_id: "writer",
                     occurred_at: Time.current, received_at: Time.current, payload_bytes: payload.bytesize,
                     signature_state: "invalid", key_fingerprint: "aa")
    end
    get alerts_path
    assert_response :success
    assert_select "td.mono", text: "signature_failure"
    assert_equal 1, Alert.where(kind: "signature_failure").count
    assert_equal 2, Alert.first.count
  end
end
