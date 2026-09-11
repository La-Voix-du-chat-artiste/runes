require "test_helper"

# The board folds the packet stream into Planned / Working / Done. These tests
# use the payload shapes the dispatcher actually publishes, because the whole
# value of the board is that it is derived and not invented.
class BoardKanbanTest < ActiveSupport::TestCase
  setup do
    Packet.delete_all
    @now = Time.current
  end

  # --- the motion a board exists to show -----------------------------------

  test "a planned step becomes the same card when it starts, and finishes when it ends" do
    progress("req-1", "prompt_received", { "prompt" => "review the diff" })
    progress("req-1", "plan_ready", { "steps" => 2 })

    board = board_for
    assert_equal ["step 1", "step 2"], titles(board, Board::Kanban::PLANNED).sort
    assert_equal 1, board.columns[Board::Kanban::WORKING].size, "the request itself is working"

    progress("req-1", "step_start", { "step" => 1, "tool" => "read_file" })
    board = board_for
    working = board.columns[Board::Kanban::WORKING].map(&:title)
    assert_includes working, "read_file"
    assert_equal ["step 2"], titles(board, Board::Kanban::PLANNED)

    progress("req-1", "step_end", { "step" => 1, "tool" => "read_file", "outcome" => "42 lines" })
    progress("req-1", "prompt_complete", {})

    board = board_for
    done = board.columns[Board::Kanban::DONE].map(&:title)
    # The step cards and the request card itself all finish: the request is a
    # unit of work too, and its card carries the plan size.
    assert_includes done, "read_file"
    assert_includes done, "step 2"
    assert_includes done, "review the diff"
    # The step the plan announced but never reached is closed (the request is
    # over) and flagged: closing is not the same as doing.
    unreached = board.cards.find { |c| c.title == "step 2" }
    assert_equal "not started when the request finished", unreached.detail
    assert unreached.error
    assert_empty board.columns[Board::Kanban::PLANNED]
    assert_empty board.columns[Board::Kanban::WORKING]
    assert_equal "42 lines", board.cards.find { |c| c.title == "read_file" }.detail
  end

  test "a finished request closes the steps nobody closed explicitly" do
    progress("req-2", "plan_ready", { "steps" => 3 })
    progress("req-2", "step_start", { "step" => 1, "tool" => "cmd" })
    progress("req-2", "prompt_complete", {})

    working = board_for.columns[Board::Kanban::WORKING]
    assert_empty working, "a step left open when the request ended is not still being worked on"
    assert_includes board_for.columns[Board::Kanban::DONE].map(&:detail), "closed with the request"
  end

  # --- the mission flow carries real titles --------------------------------

  test "a mission moves from written to running to done, with titled todo cards" do
    progress("req-3", "mission_written", { "path" => "docs/missions/alpha.md", "todos" => 2 })
    assert_equal Board::Kanban::PLANNED, column_of(board_for, "alpha")
    assert_includes title_of(board_for, "alpha"), "2 todo(s) written"

    progress("req-3", "mission_started", { "path" => "docs/missions/alpha.md",
                                           "total" => 2, "pending" => 2 })
    assert_equal Board::Kanban::WORKING, column_of(board_for, "alpha")
    assert_includes title_of(board_for, "alpha"), "2 of 2 todo(s) pending"

    progress("req-3", "mission_step_start", { "todo_id" => "t1", "title" => "Write the migration" })
    assert_equal Board::Kanban::WORKING, column_of(board_for, "Write the migration")

    progress("req-3", "mission_step_done", { "todo_id" => "t1", "title" => "Write the migration",
                                             "verdict" => "pass" })
    progress("req-3", "mission_complete", { "path" => "docs/missions/alpha.md" })

    board = board_for
    assert_equal Board::Kanban::DONE, column_of(board, "Write the migration")
    assert_equal Board::Kanban::DONE, column_of(board, "alpha")
  end

  test "a failed mission step lands in Done, flagged" do
    progress("req-4", "mission_step_failed", { "todo_id" => "t9", "title" => "Deploy",
                                               "verdict" => "fail" })

    card = board_for.cards.find { |c| c.title == "Deploy" }
    assert_equal Board::Kanban::DONE, card.column
    assert card.error
    assert_match(/\A⚠ /, card.label)
    assert_includes card.label, "fail"
  end

  # --- the journal is history, and history must not lie --------------------

  test "a journal entry with no progress events still yields a titled finished card" do
    journal("req-5", "complete", prompt: "summarize the incident", summary: "wrote report.md")

    card = board_for.cards.first
    assert_equal Board::Kanban::DONE, card.column
    assert_equal "summarize the incident", card.title
    assert_includes card.detail, "complete"
    assert_includes card.detail, "wrote report.md"
  end

  test "a mission_step journal entry closes that todo and leaves the mission running" do
    progress("req-6", "mission_started", { "path" => "docs/missions/beta.md", "total" => 2, "pending" => 2 })
    journal("req-6", "mission_step", prompt: "todo t1: Ship the thing", summary: "pass: it works")

    board = board_for
    todo = board.cards.find { |c| c.title == "Ship the thing" }
    assert_equal Board::Kanban::DONE, todo.column
    assert_includes todo.detail, "mission_step"
    assert_equal Board::Kanban::WORKING, column_of(board, "beta"),
                 "one todo finishing must not finish the mission"
  end

  test "a mid-lifecycle journal entry annotates without moving the card" do
    progress("req-7", "mission_started", { "path" => "docs/missions/gamma.md", "total" => 1, "pending" => 1 })
    journal("req-7", "mission_planning", prompt: "gamma")

    assert_equal Board::Kanban::WORKING, column_of(board_for, "gamma")
  end

  # --- other sources of work ----------------------------------------------

  test "an addressed A2A task is planned work for its agent" do
    Packet.create!(topic: "$a2a/v1/tasks/runes/host/runes-alpha", kind: "a2a_task",
                   payload: JSON.generate("method" => "tasks/send",
                                          "params" => { "prompt" => "audit the ACLs" },
                                          "request_id" => "a2a-1"),
                   event: nil, agent_id: "runes-alpha", request_id: "a2a-1",
                   occurred_at: @now, received_at: @now, payload_bytes: 2)

    card = board_for.cards.find { |c| c.title == "audit the ACLs" }
    assert_equal Board::Kanban::PLANNED, card.column
    assert_equal "runes-alpha", card.agent
  end

  test "a planner error finishes the request, flagged, with the reason" do
    progress("req-8", "planner_error", { "error" => "provider 500" })

    card = board_for.cards.find { |c| c.request_id == "req-8" }
    assert_equal Board::Kanban::DONE, card.column
    assert card.error
    assert_includes card.label, "planner_error"
  end

  # --- honesty about the data ---------------------------------------------

  test "a working card with no recent signal is shown as stale, not moved" do
    progress("req-9", "prompt_received", { "prompt" => "wedged" }, at: @now - 2.hours)

    card = board_for.cards.find { |c| c.title == "wedged" }
    assert_equal Board::Kanban::WORKING, card.column
    assert card.stale?(@now)
    assert_match(/\A⚠ /, card.label)
  end

  test "the window keeps the board about now" do
    progress("old", "prompt_received", { "prompt" => "last week" }, at: @now - 3.days)
    progress("new", "prompt_received", { "prompt" => "just now" }, at: @now - 1.minute)

    titles = board_for(window: 24.hours).cards.map(&:title)
    assert_includes titles, "just now"
    refute_includes titles, "last week"
  end

  test "the board can be narrowed to one agent" do
    progress("a", "prompt_received", { "prompt" => "alpha work" }, agent: "runes-alpha")
    progress("b", "prompt_received", { "prompt" => "beta work" }, agent: "runes-beta")

    board = board_for(agent_id: "runes-alpha")
    assert_equal ["alpha work"], board.cards.map(&:title)
    assert_equal %w[runes-alpha runes-beta], board_for.agents.sort
  end

  test "cards are bounded per column and the diagram says what was left out" do
    10.times { |i| progress("req-#{i}", "prompt_received", { "prompt" => "job #{i}" }) }

    board = board_for(limit: 3)
    assert_equal 3, board.columns[Board::Kanban::WORKING].size
    assert_equal 7, board.truncated[Board::Kanban::WORKING]
    assert_includes board.to_mmd, "truncated: 7"
  end

  test "the newest card is first in its column" do
    progress("old", "prompt_received", { "prompt" => "older" }, at: @now - 10.minutes)
    progress("new", "prompt_received", { "prompt" => "newer" }, at: @now - 1.minute)

    assert_equal ["newer", "older"], board_for.columns[Board::Kanban::WORKING].map(&:title)
  end

  # --- the artifact: valid Mermaid kanban ----------------------------------

  test "the generated diagram is valid Kanban syntax" do
    seed_a_busy_board
    mmd = board_for.to_mmd

    assert_empty Board::Kanban.validate(mmd), "generated diagram must be valid: #{mmd}"
    assert_includes mmd, "kanban"
    assert_includes mmd, "planned[Planned]"
    assert_includes mmd, "working[Working]"
    assert_includes mmd, "done[Done]"
    assert_includes mmd, "%% window: last 24 h"
    assert_includes mmd, "agent: all"
  end

  test "a label that would break the diagram is escaped, not emitted raw" do
    progress("req-quote", "prompt_received", { "prompt" => %(he said "deploy" [now] {fast}) })

    mmd = board_for.to_mmd
    assert_empty Board::Kanban.validate(mmd)
    refute_includes mmd, %(""")
    assert_includes mmd, "'deploy'"
    refute_includes mmd, "[now]"
  end

  test "the validator catches the ways a diagram can be malformed" do
    def errors(text) = Board::Kanban.validate(text).join("; ")

    assert_includes errors("kanban\n  bogus[Nowhere]\n"), "unknown column"
    assert_includes errors(%(kanban\n  planned[Planned]\n  done[Done]\nt1["stray"]\n)),
                    "not kanban syntax"
    assert_includes errors(%(kanban\n  planned[Planned]\n    c1["a"]\n    c1["b"]\n)),
                    "duplicate card id"
    assert_includes errors(%(kanban\n  planned[Planned]\n    c1["  "]\n)), "empty card label"
    assert_includes errors(%(  planned[Planned]\nkanban\n)), "first non-comment line"
    assert_empty Board::Kanban.validate(%(kanban\n  planned[Planned]\n    c1["ok"]\n))
  end

  test "an empty stream yields a valid, empty board" do
    mmd = board_for.to_mmd

    assert_empty Board::Kanban.validate(mmd)
    assert_empty board_for.cards
    assert_includes mmd, "cards: 0"
  end

  private

  def seed_a_busy_board
    progress("b1", "mission_written", { "path" => "docs/missions/one.md", "todos" => 2 })
    progress("b1", "mission_step_start", { "todo_id" => "t1", "title" => "First todo" })
    progress("b1", "mission_step_done", { "todo_id" => "t1", "title" => "First todo", "verdict" => "pass" })
    progress("b2", "prompt_received", { "prompt" => "busy work" })
    progress("b2", "plan_ready", { "steps" => 1 })
    progress("b3", "plan_empty", {})
    journal("b4", "complete", prompt: "historical work", summary: "done")
  end

  def board_for(window: 24.hours, agent_id: nil, limit: Board::Kanban::DEFAULT_LIMIT)
    Board::Kanban.new(window: window, agent_id: agent_id, limit: limit, now: @now)
  end

  def progress(request_id, event, fields = {}, at: nil, agent: nil)
    Packet.create!(
      topic: "runes/prompts/#{request_id}/progress", kind: "progress",
      payload: JSON.generate({ "request_id" => request_id, "event" => event }.merge(fields)),
      event: event, request_id: request_id, agent_id: agent,
      occurred_at: at || @now, received_at: at || @now, payload_bytes: 40
    )
  end

  def journal(request_id, status, prompt:, summary: nil, at: nil, agent: nil)
    Packet.create!(
      topic: "runes/_log/prompts", kind: "journal",
      payload: JSON.generate({ "request_id" => request_id, "agent" => agent, "prompt" => prompt,
                               "status" => status, "at" => (at || @now).utc.iso8601,
                               "summary" => summary }.compact),
      event: nil, request_id: request_id, agent_id: agent,
      occurred_at: at || @now, received_at: at || @now, payload_bytes: 60
    )
  end

  def titles(board, column)
    board.columns[column].map(&:title)
  end

  def column_of(board, title_fragment)
    card = board.cards.find { |c| c.title.to_s.include?(title_fragment) }
    card&.column
  end

  def title_of(board, title_fragment)
    board.cards.find { |c| c.title.to_s.include?(title_fragment) }&.label.to_s
  end
  # --- a workflow run is visible on the same board -------------------------

  # `RUNES_TELEMETRY=mqtt bin/runes-workflow execute examples/prospect_pipeline.rb`
  # projects run + step rows; those are cards here, which is what makes a
  # pipeline run watchable rather than only grep-able.
  test "workflow steps appear as cards, placed by their status" do
    run = WorkflowRun.create!(run_id: "run-1", workflow: "prospect_pipeline.rb",
                              status: "running", started_at: @now - 3.minutes,
                              step_count: 3)
    WorkflowStep.create!(workflow_run: run, position: 0, name: "brainstorm", rune: "agent",
                         status: "ok", started_at: @now - 3.minutes,
                         finished_at: @now - 2.minutes, duration_ms: 1_200)
    WorkflowStep.create!(workflow_run: run, position: 1, name: "plan", rune: "agent",
                         status: "running", started_at: @now - 1.minute)
    WorkflowStep.create!(workflow_run: run, position: 2, name: "crm", rune: "ruby",
                         status: "failed", started_at: @now - 30.seconds,
                         finished_at: @now - 20.seconds, error: "index exploded")

    board = board_for

    assert_equal ["brainstorm"], titles(board, Board::Kanban::DONE).grep(/brainstorm/)
    assert_equal ["plan"], titles(board, Board::Kanban::WORKING)
    crm = board.cards.find { |card| card.title == "crm" }
    assert_equal Board::Kanban::DONE, crm.column
    assert crm.error
    assert_includes crm.detail, "index exploded"
    assert_includes crm.detail, "prospect_pipeline.rb"
    assert_includes crm.detail, "ruby", "the rune is named"
  end

  test "a workflow run is not a planned board: the engine names a step when it starts" do
    run = WorkflowRun.create!(run_id: "run-2", workflow: "w.rb", status: "running",
                              started_at: @now)
    WorkflowStep.create!(workflow_run: run, position: 0, name: "only", rune: "ruby",
                         status: "running", started_at: @now)

    board = board_for
    assert_empty board.columns[Board::Kanban::PLANNED]
    assert_equal ["only"], board.columns[Board::Kanban::WORKING].map(&:title)
  end

  test "a workflow card is badged with its agent when the run has one" do
    run = WorkflowRun.create!(run_id: "run-3", workflow: "w.rb", status: "running",
                              agent_id: "runes-alpha", started_at: @now)
    WorkflowStep.create!(workflow_run: run, position: 0, name: "step", rune: "agent",
                         status: "running", started_at: @now)

    card = board_for.cards.find { |c| c.title == "step" }
    assert_equal "runes-alpha", card.agent
  end

  test "workflow cards keep the diagram valid" do
    run = WorkflowRun.create!(run_id: "run-4", workflow: "w.rb", status: "running",
                              started_at: @now)
    WorkflowStep.create!(workflow_run: run, position: 0, name: %(weird "name" [x]),
                         rune: "ruby", status: "running", started_at: @now)

    assert_empty Board::Kanban.validate(board_for.to_mmd)
  end
end
