require "test_helper"

class RunsControllerTest < ActionDispatch::IntegrationTest
  setup do
    WorkflowStep.delete_all
    WorkflowRun.delete_all
    Packet.delete_all

    @run = WorkflowRun.create!(
      run_id: "abc123def456", workflow: "/tmp/examples/analyze_codebase.rb", status: "failed",
      started_at: 3.seconds.ago, finished_at: 1.second.ago, duration_ms: 2000.0,
      step_count: 2, error: "Runes::ControlFlow::FailCog: Process exited with status code 3",
      params: JSON.generate("targets" => ["chat_summary"], "kwargs" => { "env" => "staging" })
    )
    @first = @run.workflow_steps.create!(
      position: 1, rune: "cmd", name: "recent_changes", status: "ok", duration_ms: 12.5,
      started_at: @run.started_at, finished_at: @run.started_at + 0.0125,
      output: "app/models/user.rb\n"
    )
    @second = @run.workflow_steps.create!(
      position: 2, rune: "chat", name: "summary", status: "failed", duration_ms: 1980.0,
      started_at: @run.started_at + 0.02, finished_at: @run.finished_at,
      error: "Chat::MaxTokensExceededError: too long"
    )
  end

  def test_index_lists_runs_with_their_shape
    get runs_path

    assert_response :success
    assert_match "analyze_codebase.rb", response.body
    assert_match "abc123def456", response.body
    assert_match "failed", response.body
    # the duration bar is proportional to the slowest run on the page
    assert_match(/bar__fill bar__fill--failed/, response.body)
  end

  def test_index_filters_by_status
    get runs_path(status: "ok")
    assert_response :success
    assert_no_match(/abc123def456/, response.body)

    get runs_path(status: "failed")
    assert_match "abc123def456", response.body
  end

  def test_index_filters_by_query
    get runs_path(q: "analyze")
    assert_match "abc123def456", response.body

    get runs_path(q: "nothing-matches-this")
    assert_response :success
    assert_no_match(/abc123def456/, response.body)
  end

  def test_show_draws_the_timeline_and_the_steps
    get run_path(@run.run_id)

    assert_response :success
    assert_match "analyze_codebase.rb", response.body
    assert_match "Timeline", response.body
    # both step bars, positioned on the shared track
    assert_equal 2, response.body.scan(/timeline__bar timeline__bar--/).size
    assert_match "recent_changes", response.body
    assert_match "summary", response.body
    assert_match "app/models/user.rb", response.body
    assert_match "MaxTokensExceededError", response.body
    # the run's own error is surfaced too
    assert_match "Process exited with status code 3", response.body
    # parameters are shown as chips
    assert_match "chat_summary", response.body
    assert_match "env", response.body
  end

  def test_show_surfaces_packets_carrying_the_run_id
    PacketRecorder.record(
      topic: "runes/workflows/#{@run.run_id}/step_finished",
      payload: JSON.generate("run_id" => @run.run_id, "kind" => "step_finished",
                             "rune" => "chat", "name" => "summary", "status" => "failed",
                             "at" => Time.now.utc.iso8601(3))
    )

    get run_path(@run.run_id)

    assert_response :success
    assert_match "Packets from this run", response.body
  end

  def test_a_run_with_no_steps_still_renders
    bare = WorkflowRun.create!(run_id: "bare0001", workflow: "/tmp/x.rb", status: "running",
                               started_at: Time.current)

    get run_path(bare.run_id)

    assert_response :success
    assert_match(/No steps recorded yet/, response.body)
  end

  def test_an_unknown_run_is_a_404_not_a_500
    get run_path("does-not-exist")

    assert_response :not_found
  end
end
