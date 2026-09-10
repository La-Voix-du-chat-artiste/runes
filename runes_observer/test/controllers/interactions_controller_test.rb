require "test_helper"

class InteractionsControllerTest < ActionDispatch::IntegrationTest
  test "shows every packet of a request, oldest first" do
    get interaction_path("req-1")

    assert_response :success
    assert_match "write a greeting file", response.body
    assert_match "runes/prompts/req-1/response", response.body
    assert_match "runes-alpha", response.body
    assert_match "request", response.body
  end

  test "groups a delegated task reply under its request id" do
    get interaction_path("req-2")

    assert_response :success
    assert_match "runes/agents/runes-beta/tasks/req-2/response", response.body
    assert_match "runes-beta", response.body
  end

  test "an unknown correlation id renders an empty timeline" do
    get interaction_path("nope")

    assert_response :success
    assert_match "No packet carries this id", response.body
  end
end
