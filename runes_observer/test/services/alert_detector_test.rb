require "test_helper"

# O1.5 acceptance: each detector has a fixture that fires it and one that
# must not.
class AlertDetectorTest < ActiveSupport::TestCase
  setup do
    Packet.delete_all
    Alert.delete_all
  end

  def packet(agent_id:, fingerprint:, signature_state: "unsigned", at: Time.current)
    payload = JSON.generate("agent_id" => agent_id)
    Packet.create!(topic: "runes/prompts", payload: payload, kind: "prompt", agent_id: agent_id,
                   occurred_at: at, received_at: at, payload_bytes: payload.bytesize,
                   signature_state: signature_state, key_fingerprint: fingerprint)
  end

  def test_impersonation_detector_fires_on_split_identity
    packet(agent_id: "writer", fingerprint: "aa")
    packet(agent_id: "writer", fingerprint: "bb")
    alerts = AlertDetector.call
    imp = alerts.select { |a| a.kind == "impersonation" }
    assert_equal 1, imp.size
    assert_equal "writer", imp.first.subject
    assert_equal "error", imp.first.severity
    assert_equal 1, imp.first.count
  end

  def test_impersonation_detector_does_not_fire_on_one_key
    packet(agent_id: "writer", fingerprint: "aa")
    packet(agent_id: "writer", fingerprint: "aa")
    alerts = AlertDetector.call
    assert_empty alerts.select { |a| a.kind == "impersonation" }
  end

  def test_signature_failure_detector_fires_and_dedupes
    packet(agent_id: "writer", fingerprint: "aa", signature_state: "invalid")
    packet(agent_id: "writer", fingerprint: "aa", signature_state: "invalid")
    packet(agent_id: "writer", fingerprint: "aa", signature_state: "verified")
    alerts = AlertDetector.call
    sig = alerts.select { |a| a.kind == "signature_failure" }
    assert_equal 1, sig.size
    assert_equal "writer", sig.first.subject
    assert_equal 2, sig.first.count, "two invalid packets, one deduped row"
  end

  def test_signature_failure_detector_ignores_verified_and_unsigned
    packet(agent_id: "writer", fingerprint: "aa", signature_state: "verified")
    packet(agent_id: "writer", fingerprint: nil, signature_state: "unsigned")
    alerts = AlertDetector.call
    assert_empty alerts.select { |a| a.kind == "signature_failure" }
  end
end
