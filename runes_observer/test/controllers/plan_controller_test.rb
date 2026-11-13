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

  # --- slice 3 write actions ------------------------------------------------

  test "create_epic writes the file and redirects" do
    assert_difference -> { MissionStore.epics.size }, 1 do
      post plan_epics_path, params: { body: "# From the UI\n\nDo the thing." }
    end

    assert_redirected_to plan_path
    epic = MissionStore.epics.first
    assert_equal "From the UI", epic.title
    assert_match(/E-1-from-the-ui\.md\z/, epic.path)
  end

  test "create_epic with an empty body redirects with an alert" do
    post plan_epics_path, params: { body: "  " }
    assert_redirected_to plan_path
    assert_match "empty", flash[:alert]
  end

  test "plan_epic publishes the plan envelope to runes/prompts" do
    old_transport = ENV["RUNES_TRANSPORT"]
    old_publish = ENV["RUNES_OBSERVER_PUBLISH"]
    ENV["RUNES_TRANSPORT"] = "inproc"
    ENV["RUNES_OBSERVER_PUBLISH"] = "on"
    FabricPublisher.reset!
    Runes::Transport::InProcess.reset!

    received = Queue.new
    listener = Runes::Transport.build(kind: "inproc")
    listener.connect
    listener.subscribe("runes/prompts") { |msg| received << JSON.parse(msg.payload) }

    post plan_epic_path("e1-launch")

    assert_redirected_to plan_path
    envelope = received.pop
    assert_equal "plan", envelope["mode"]
    assert_match(%r{docs/epics/e1-launch\.md\z}, envelope["epic_path"])
    assert envelope["request_id"].present?
  ensure
    listener&.disconnect
    FabricPublisher.reset!
    Runes::Transport::InProcess.reset!
    ENV["RUNES_TRANSPORT"] = old_transport
    ENV["RUNES_OBSERVER_PUBLISH"] = old_publish
  end

  test "plan_epic 404s on unknown epics" do
    post plan_epic_path("nope")
    assert_response :not_found
  end

  test "move_card moves the card, journals it and announces it on the fabric" do
    old_transport = ENV["RUNES_TRANSPORT"]
    old_publish = ENV["RUNES_OBSERVER_PUBLISH"]
    old_journal = ENV["RUNES_OBSERVER_JOURNAL"]
    journal = File.join(@tmp, "journal.jsonl")
    ENV["RUNES_TRANSPORT"] = "inproc"
    ENV["RUNES_OBSERVER_PUBLISH"] = "on"
    ENV["RUNES_OBSERVER_JOURNAL"] = journal
    FabricPublisher.reset!
    Runes::Transport::InProcess.reset!

    moved = Queue.new
    listener = Runes::Transport.build(kind: "inproc")
    listener.connect
    listener.subscribe("runes/board/moved") { |msg| moved << JSON.parse(msg.payload) }

    post move_plan_card_path("m1-contact", index: 0), params: { to: "done" }, as: :json

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal "todo", body["from"]
    assert_equal "done", body["to"]
    assert_equal "Call", body["title"]

    reparsed = Runes::Kanban.parse(File.read(File.join(@tmp, "docs", "missions", "m1-contact.mmd")))
    assert_equal 2, reparsed[:columns]["done"].size
    assert_equal "Call", reparsed[:columns]["done"].last.title

    announcement = moved.pop
    assert_equal "m1-contact", announcement["mission"]
    assert_equal "done", announcement["to"]

    entry = JSON.parse(File.readlines(journal).last)
    assert_equal "board_card_moved", entry["event"]
    assert_equal "m1-contact", entry["mission"]
  ensure
    listener&.disconnect
    FabricPublisher.reset!
    Runes::Transport::InProcess.reset!
    ENV["RUNES_TRANSPORT"] = old_transport
    ENV["RUNES_OBSERVER_PUBLISH"] = old_publish
    ENV["RUNES_OBSERVER_JOURNAL"] = old_journal
  end

  test "move_card with a bad column is 422" do
    post move_plan_card_path("m1-contact", index: 0), params: { to: "sideways" }, as: :json
    assert_response :unprocessable_entity
  end

  test "move_card 404s on unknown missions" do
    post move_plan_card_path("nope", index: 0), params: { to: "done" }, as: :json
    assert_response :not_found
  end
end
