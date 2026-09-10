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
end
