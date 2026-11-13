require "test_helper"

# Slice 1 of docs/WORKSPACE_PLAN.md: the workspace shell embeds the live
# feed, the board, the agents and the runs on one page (root).
class WorkspaceControllerTest < ActionDispatch::IntegrationTest
  test "root renders all four panels with the seeded fabric" do
    get root_path

    assert_response :success
    assert_match "Workspace", response.body
    # Communication: the live feed with the fixture packets.
    assert_match "Communication", response.body
    assert_match "runes-alpha", response.body
    assert_match "runes/prompts/req-1/progress", response.body
    # Mes tâches: the board columns.
    assert_match "Mes tâches", response.body
    assert_match "Planned", response.body
    assert_match "Working", response.body
    assert_match "Done", response.body
    # Agents + runs panels.
    assert_match "Agents", response.body
    assert_match "Flux de travail", response.body
    # The feed poller is wired so the panel is live, not a static snapshot.
    assert_match 'data-controller="feed"', response.body
    assert_match feed_path, response.body
  end

  test "shows the empty state when nothing has been observed" do
    Packet.delete_all
    Agent.delete_all

    get root_path

    assert_response :success
    assert_match "Nothing observed yet", response.body
    assert_match "runes:demo", response.body
  end

  test "the nav links to the workspace and the dashboard" do
    get root_path

    assert_response :success
    assert_match dashboard_path, response.body
    assert_match board_path, response.body
    assert_match agents_path, response.body
    assert_match runs_path, response.body
  end

  test "the dashboard stays reachable at /dashboard" do
    get dashboard_path

    assert_response :success
    assert_match "Fleet", response.body
    assert_match "Live packets", response.body
  end
end
