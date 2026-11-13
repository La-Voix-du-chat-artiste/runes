require "test_helper"
require "tmpdir"

class MissionStoreTest < ActiveSupport::TestCase
  setup do
    @tmp = Dir.mktmpdir("runes-workspace")
    FileUtils.mkdir_p(File.join(@tmp, "docs", "epics"))
    FileUtils.mkdir_p(File.join(@tmp, "docs", "missions"))
    @old = ENV["RUNES_OBSERVER_WORKSPACE"]
    ENV["RUNES_OBSERVER_WORKSPACE"] = @tmp
    MissionStore.reset_cache!

    File.write(File.join(@tmp, "docs", "epics", "20261112-090000-abc-launch.md"), "# Launch product Alpha\n\nBody.\n")
    File.write(File.join(@tmp, "docs", "missions", "20261112-100000-def-contact.md"), "# Contacter 10 prospects\n\nMission body.\n")
    File.write(File.join(@tmp, "docs", "missions", "20261112-100000-def-contact.json"),
               JSON.generate("mission_title" => "Contacter 10 prospects", "source" => "epic:launch",
                             "source_path" => "docs/epics/20261112-090000-abc-launch.md",
                             "todos" => ["Appeler Jean", { "title" => "Envoyer email" }]))
    File.write(File.join(@tmp, "docs", "missions", "20261112-100000-def-contact.mmd"), <<~MMD)
      %% Code: M-001
      %% Mission: Contacter 10 prospects
      kanban
        Todo:
          - [ ] Appeler Jean (Assigné: Jean)
        In Progress:
        Done:
          - [x] Identifier les prospects
        Blocked:
    MMD
  end

  teardown do
    ENV["RUNES_OBSERVER_WORKSPACE"] = @old
    MissionStore.reset_cache!
    FileUtils.remove_entry(@tmp)
  end

  test "root comes from RUNES_OBSERVER_WORKSPACE" do
    assert_equal @tmp, MissionStore.root
  end

  test "epics are listed newest first with their heading as title" do
    epics = MissionStore.epics
    assert_equal 1, epics.size
    assert_equal "Launch product Alpha", epics.first.title
    assert_match(/launch\z/, epics.first.id)
  end

  test "missions read the sidecar title and todos" do
    missions = MissionStore.missions
    assert_equal 1, missions.size
    m = missions.first
    assert_equal "Contacter 10 prospects", m.title
    assert_equal "epic:launch", m.source
    assert_equal 2, m.todos.size
  end

  test "find_mission is containment-checked" do
    assert_nil MissionStore.find_mission("../epics/20261112-090000-abc-launch")
    assert_nil MissionStore.find_mission("nope")
    assert_not_nil MissionStore.find_mission("20261112-100000-def-contact")
  end

  test "board_for parses the .mmd through Runes::Kanban when present" do
    m = MissionStore.find_mission("20261112-100000-def-contact")
    board = MissionStore.board_for(m)

    assert_equal :file, board[:source]
    assert_equal 1, board[:columns]["todo"].size
    assert_equal "Appeler Jean", board[:columns]["todo"].first[:title]
    assert_equal "Jean", board[:columns]["todo"].first[:assignee]
    assert_equal 1, board[:columns]["done"].size
    assert board[:columns]["done"].first[:done]
    assert_equal "M-001", board[:header]["code"]
  end

  test "board_for derives from sidecar todos when there is no .mmd" do
    File.delete(File.join(@tmp, "docs", "missions", "20261112-100000-def-contact.mmd"))
    m = MissionStore.find_mission("20261112-100000-def-contact")
    board = MissionStore.board_for(m)

    assert_equal :derived, board[:source]
    assert_equal 2, board[:columns]["todo"].size
    assert_equal "Envoyer email", board[:columns]["todo"].last[:title]
  end

  test "empty workspace lists nothing" do
    ENV["RUNES_OBSERVER_WORKSPACE"] = Dir.mktmpdir("empty-ws")
    MissionStore.reset_cache!
    assert_equal [], MissionStore.epics
    assert_equal [], MissionStore.missions
  end
end
