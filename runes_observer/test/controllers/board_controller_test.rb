require "test_helper"

# The board is read-only, so what matters is that it tells the truth about the
# fleet and that both renderings — the Mermaid diagram and the HTML fallback —
# come from the same folded data.
class BoardControllerTest < ActionDispatch::IntegrationTest
  setup do
    Packet.delete_all
    @now = Time.current
    progress("req-1", "prompt_received", { "prompt" => "review the diff" }, agent: "runes-alpha")
    progress("req-1", "plan_ready", { "steps" => 2 }, agent: "runes-alpha")
    progress("req-1", "step_start", { "step" => 1, "tool" => "read_file" }, agent: "runes-alpha")
    progress("req-2", "mission_step_start", { "todo_id" => "t1", "title" => "Write the migration" },
             agent: "runes-beta")
    progress("req-2", "mission_step_done", { "todo_id" => "t1", "title" => "Write the migration",
                                             "verdict" => "pass" }, agent: "runes-beta")
  end

  test "the page renders the three columns with their cards" do
    get board_path

    assert_response :success
    assert_match "Planned", response.body
    assert_match "Working", response.body
    assert_match "Done", response.body
    assert_match "review the diff", response.body
    assert_match "read_file", response.body
    assert_match "Write the migration", response.body
    assert_match "runes-alpha", response.body
  end

  # The diagram is the deliverable and the HTML is the fallback, so both must be
  # on the page — the second one is what a no-JS browser (or a Mermaid failure)
  # shows.
  test "the page carries the diagram text and a server-rendered board" do
    get board_path

    assert_match 'data-controller="kanban"', response.body
    assert_match 'data-kanban-target="source"', response.body
    assert_match 'data-kanban-target="canvas"', response.body
    assert_match "kanban", response.body
    assert_match "planned[Planned]", response.body
    assert_match "kanban-board", response.body
    assert_match "kanban-card--working", response.body
  end

  # Mermaid is vendored precisely so this is a local request.
  test "the page loads the vendored mermaid bundle, not a CDN" do
    get board_path

    assert_match %r{/assets/mermaid\.min(-[0-9a-f]+)?\.js}, response.body
    refute_match %r{https?://}, response.body.split("mermaid").last.to_s[0, 400]
  end

  test "board.mmd returns the artifact as plain text" do
    get board_mmd_path

    assert_response :success
    assert_match %r{\Atext/plain}, response.content_type
    assert_match "kanban", response.body
    assert_empty Board::Kanban.validate(response.body)
  end

  test "the diagram describes the same work the page lists" do
    get board_mmd_path

    assert_match "read_file", response.body
    assert_match "Write the migration", response.body
    assert_match "runes-alpha", response.body
  end

  test "filtering by agent narrows both renderings" do
    get board_path(agent_id: "runes-beta")
    assert_response :success
    assert_match "Write the migration", response.body
    refute_match "review the diff", response.body

    get board_mmd_path(agent_id: "runes-beta")
    assert_match "Write the migration", response.body
    refute_match "review the diff", response.body
  end

  test "the window and the card limit are applied and reflected" do
    get board_path(hours: 1, limit: 1)

    assert_response :success
    assert_match "last 1 h", response.body.gsub(/\s+/, " ")
  end

  test "an empty board explains itself instead of looking broken" do
    Packet.delete_all

    get board_path

    assert_response :success
    assert_match "Nothing announced yet", response.body
    assert_match "Nothing running", response.body
    assert_match "Nothing finished in this window", response.body
    assert_match "board.mmd", response.body
  end

  test "the layout links to the board" do
    get root_path

    assert_response :success
    assert_match board_path, response.body
  end

  private

  def progress(request_id, event, fields = {}, at: nil, agent: nil)
    Packet.create!(
      topic: "runes/prompts/#{request_id}/progress", kind: "progress",
      payload: JSON.generate({ "request_id" => request_id, "event" => event }.merge(fields)),
      event: event, request_id: request_id, agent_id: agent,
      occurred_at: at || @now, received_at: at || @now, payload_bytes: 40
    )
  end
end
