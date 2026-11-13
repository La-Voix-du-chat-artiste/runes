require "test_helper"
require "tmpdir"

# Workspace slice 2C: the plan read view over the workspace docs dir.
class PlanControllerTest < ActionDispatch::IntegrationTest
  setup do
    @tmp = Dir.mktmpdir("runes-workspace")
    FileUtils.mkdir_p(File.join(@tmp, "docs", "epics"))
    FileUtils.mkdir_p(File.join(@tmp, "docs", "missions"))
    @old = ENV["RUNES_OBSERVER_WORKSPACE"]
    ENV["RUNES_OBSERVER_WORKSPACE"] = @tmp
    MissionStore.reset_cache!

    File.write(File.join(@tmp, "docs", "epics", "e1-launch.md"), "# Launch Alpha\n")
    File.write(File.join(@tmp, "docs", "missions", "m1-contact.md"), "# Contact prospects\n")
    File.write(File.join(@tmp, "docs", "missions", "m1-contact.json"),
               JSON.generate("mission_title" => "Contact prospects", "todos" => %w[Call Write]))
    File.write(File.join(@tmp, "docs", "missions", "m1-contact.mmd"), <<~MMD)
      %% Mission: Contact prospects
      kanban
        Todo:
          - [ ] Call
        In Progress:
        Done:
          - [x] Write
        Blocked:
    MMD
  end

  teardown do
    ENV["RUNES_OBSERVER_WORKSPACE"] = @old
    MissionStore.reset_cache!
    FileUtils.remove_entry(@tmp)
  end

  test "index lists epics and missions with board badges" do
    get plan_path

    assert_response :success
    assert_match "Plan", response.body
    assert_match "Launch Alpha", response.body
    assert_match "Contact prospects", response.body
    assert_match "mmd board", response.body
    assert_match @tmp, response.body
  end

  test "index shows the empty state without a workspace" do
    ENV["RUNES_OBSERVER_WORKSPACE"] = Dir.mktmpdir("empty-ws")
    MissionStore.reset_cache!

    get plan_path

    assert_response :success
    assert_match "No epic yet", response.body
    assert_match "No mission yet", response.body
  end

  test "show renders the mission board from the .mmd" do
    get plan_mission_path("m1-contact")

    assert_response :success
    assert_match "Contact prospects", response.body
    assert_match "Todo", response.body
    assert_match "Call", response.body
    assert_match "Write", response.body
    assert_match "done", response.body
    assert_match "m1-contact.mmd", response.body
  end

  test "show 404s on unknown or traversal ids" do
    get plan_mission_path("nope")
    assert_response :not_found

    get "/plan/missions/..%2F..%2Fetc"
    assert_response :not_found
  end
end
