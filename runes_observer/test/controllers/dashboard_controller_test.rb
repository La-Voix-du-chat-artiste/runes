require "test_helper"

class DashboardControllerTest < ActionDispatch::IntegrationTest
  test "renders the fleet and the live feed" do
    get root_path

    assert_response :success
    assert_match "Fleet", response.body
    assert_match "runes-alpha", response.body
    assert_match "runes-beta", response.body
    assert_match "Live packets", response.body
    assert_match "runes/prompts/req-1/progress", response.body
  end

  test "shows how to start observing when nothing has been seen" do
    Packet.delete_all
    Agent.delete_all

    get root_path

    assert_response :success
    assert_match "Nothing observed yet", response.body
    assert_match "bin/runes-ingest", response.body
  end

  # A dashboard has to answer "is the fleet busy or silent?" at a glance, so
  # the volume chart is part of the contract, not decoration.
  test "draws the traffic volume and the kind mix" do
    base = 3.minutes.ago
    3.times do |i|
      Packet.create!(topic: "runes/prompts/burst-#{i}", kind: "prompt", request_id: "burst-#{i}",
                     payload: JSON.generate("prompt" => "hi"), occurred_at: base + i, received_at: base + i,
                     payload_bytes: 2)
    end

    get root_path

    assert_response :success
    assert_match "Traffic · last 30 min", response.body
    assert_equal 30, response.body.scan(/class="spark__bar/).size, "one bar per minute of the window"
    assert_match "what it is carrying", response.body
    assert_match(/mix__bar/, response.body)
  end

  test "renders the ingest health panel" do
    IngestStatus.mark_connected!(host: "127.0.0.1", port: 1883)

    get root_path

    assert_response :success
    assert_match "Ingest", response.body
    assert_match "127.0.0.1:1883", response.body
  end

  # O0.5: the panel has to answer "is this feed trustworthy right now?" — not
  # just "connected": over what transport, at what rate, lagging by how much,
  # and after how many rebuilds.
  test "the ingest panel shows transport, rate, lag and reconnects" do
    IngestStatus.mark_connected!(host: "127.0.0.1", port: 1883, transport: "MQTT5")
    IngestStatus.bump_reconnects!(by: 2)
    IngestStatus.bump!(at: Time.current, by: 5, lag_ms: 45_000)

    get root_path

    assert_response :success
    assert_match "MQTT5", response.body
    assert_match "reconnects", response.body
    assert_match "45.0 s", response.body
    assert_match "packets/min", response.body
    assert_match "kv__warn", response.body, "a 45 s publisher lag must be visible, not just recorded"
  end

  test "a feed with no publisher clock says unknown instead of zero" do
    IngestStatus.mark_connected!(host: "127.0.0.1", port: 1883, transport: "MQTT5")

    get root_path

    assert_response :success
    assert_match "unknown (publisher sent no clock)", response.body
    refute_match "kv__warn", response.body
  end
  # doc5.md O0.3: the panel that answers "who really published this".
  test "the security panel shows signature states and catches one agent under two keys" do
    Packet.delete_all
    alice = "a" * 64
    mallory = "b" * 64
    Packet.create!(topic: "runes/prompts", kind: "prompt", payload: "{}", payload_bytes: 2,
                   agent_id: "runes-alpha", signature_state: "verified", key_fingerprint: alice,
                   occurred_at: 5.minutes.ago, received_at: 5.minutes.ago)
    Packet.create!(topic: "runes/prompts", kind: "prompt", payload: "{}", payload_bytes: 2,
                   agent_id: "runes-alpha", signature_state: "untrusted", key_fingerprint: mallory,
                   occurred_at: 5.minutes.ago, received_at: 5.minutes.ago)
    Packet.create!(topic: "runes/prompts", kind: "prompt", payload: "{}", payload_bytes: 2,
                   agent_id: "runes-beta", signature_state: "unsigned",
                   occurred_at: 5.minutes.ago, received_at: 5.minutes.ago)

    get root_path

    assert_response :success
    assert_match "Security", response.body
    assert_match "runes-alpha", response.body
    assert_match "2 different keys", response.body
    assert_match "a" * 16, response.body
    assert_match "unsigned packet", response.body
  end

  test "require-signatures mode says loudly how much of the feed is unproven" do
    Packet.delete_all
    Packet.create!(topic: "runes/prompts", kind: "prompt", payload: "{}", payload_bytes: 2,
                   agent_id: "runes-beta", signature_state: "unsigned",
                   occurred_at: 5.minutes.ago, received_at: 5.minutes.ago)
    previous = ENV["RUNES_OBSERVER_REQUIRE_SIGNATURES"]
    ENV["RUNES_OBSERVER_REQUIRE_SIGNATURES"] = "1"
    begin
      get root_path
      assert_response :success
      assert_match "RUNES_OBSERVER_REQUIRE_SIGNATURES is on", response.body
    ensure
      previous.nil? ? ENV.delete("RUNES_OBSERVER_REQUIRE_SIGNATURES") : ENV["RUNES_OBSERVER_REQUIRE_SIGNATURES"] = previous
    end
  end

  test "with no findings the panel says so instead of staying silent" do
    get root_path

    assert_response :success
    assert_match "no findings", response.body
  end
end
