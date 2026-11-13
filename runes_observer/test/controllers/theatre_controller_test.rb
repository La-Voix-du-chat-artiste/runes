require "test_helper"

# Workspace slice 2D: /theatre renders the live graph with the Stimulus
# controller wired to the structured feed; /wall is the kiosk.
class TheatreControllerTest < ActionDispatch::IntegrationTest
  test "theatre renders the svg graph and the controller data" do
    get theatre_path

    assert_response :success
    assert_match "Theatre", response.body
    assert_match 'data-controller="theatre"', response.body
    assert_match "runes-alpha", response.body
    assert_match "runes-beta", response.body
    assert_match "data-theatre-data-value", response.body
    assert_match "fields=1", response.body
    assert_match "<svg", response.body
  end

  test "theatre shows the empty state when nothing is observed" do
    Packet.delete_all
    Agent.delete_all

    get theatre_path

    assert_response :success
    assert_match "No agents observed yet", response.body
    assert_match "runes:demo", response.body
  end

  test "wall renders the kiosk layout without the nav" do
    get wall_path

    assert_response :success
    assert_match "Theatre", response.body
    assert_match 'class="app app--kiosk"', response.body
    assert_no_match "topbar", response.body
    assert_match 'http-equiv="refresh"', response.body
  end

  test "the feed exposes structured fields with fields=1" do
    get feed_path(fields: 1, after_id: 0), as: :json

    assert_response :success
    body = JSON.parse(response.body)
    assert body["packets"].any?
    entry = body["packets"].find { |p| p["kind"] == "prompt" }
    assert_equal "runes/prompts", entry["topic"]
    assert_equal "prompt", entry["kind"]
    assert_equal "runes-alpha", entry["agent_id"]
    assert_equal "req-1", entry["request_id"]
    assert entry.key?("from")
    assert entry["html"].present?
  end

  test "the feed without fields keeps the original shape" do
    get feed_path(after_id: 0), as: :json

    assert_response :success
    body = JSON.parse(response.body)
    entry = body["packets"].first
    assert entry.key?("html")
    assert_not entry.key?("topic")
  end
end
