require "test_helper"
# The engine is not part of the observatory bundle, but this test is
# deliberately end-to-end: it runs the REAL workflow engine and feeds the
# events it emits through the same recorder the ingest uses. Loading the
# parent library is worth it - a projection test with hand-written events
# would pass while the two halves disagreed about the contract.
require_relative "../../../lib/runes/workflow"

# The run views are only worth having if a real run's events turn into them.
# This test drives the actual engine: it runs a workflow with the telemetry
# sink pointed at the in-process transport, feeds the resulting messages
# through the same PacketRecorder the ingest uses, and then asserts the run
# and its steps read correctly.
class WorkflowRunProjectionTest < ActiveSupport::TestCase
  def setup
    # The observatory's suite is not transactional (the recorder is built for a
    # long-lived process and its tests clear state explicitly), so clear here
    # too or a run from an earlier test leaks into the counts.
    WorkflowStep.delete_all
    WorkflowRun.delete_all
    Packet.delete_all
    @events = []
    Runes::Telemetry.sink = ->(event) { @events << event }
  end

  def teardown
    Runes::Telemetry.sink = nil
  end

  def run_workflow(source)
    dir = Dir.mktmpdir("runes-runs-")
    path = File.join(dir, "workflow.rb")
    File.write(path, source)
    Runes::Workflow.from_file(path, Runes::WorkflowParams.new)
  ensure
    FileUtils.remove_entry(dir) if dir && Dir.exist?(dir) && dir.start_with?(Dir.tmpdir)
  end

  # Feed one telemetry event through the observer exactly as ingest would.
  def deliver(event)
    PacketRecorder.record(
      topic: "runes/workflows/#{event['run_id']}/#{event['kind']}",
      payload: JSON.generate(event)
    )
    event
  end

  def test_a_real_run_becomes_a_run_with_steps
    run_workflow(<<~RUBY)
      execute do
        ruby(:greeting) { "hello" }
        cmd(:echo) { "echo world" }
        ruby(:check) { cmd!(:echo).out.strip }
      end
    RUBY

    assert_equal 8, @events.size, "one run_started, three step pairs, one run_finished"

    @events.each { |event| deliver(event) }

    run = WorkflowRun.find_by!(run_id: @events.first["run_id"])
    assert_equal "ok", run.status
    assert run.finished_at.present?
    assert_equal 3, run.step_count
    assert_equal 3, run.workflow_steps.count
    assert_equal %w[ruby cmd ruby], run.workflow_steps.ordered.map(&:rune)
    assert_equal %w[greeting echo check], run.workflow_steps.ordered.map(&:name)
    assert_equal [1, 2, 3], run.workflow_steps.ordered.map(&:position)

    echo = run.workflow_steps.ordered.second
    assert_equal "ok", echo.status
    assert_equal "world\n", echo.output
    assert_operator echo.duration_ms, :>=, 0
    assert echo.started_at.present?
  end

  def test_a_failing_run_records_the_error_on_the_step_and_the_run
    assert_raises(Runes::ControlFlow::FailCog) do
      run_workflow(<<~RUBY)
        execute do
          cmd(:boom) { ["ruby", "-e", "exit 3"] }
        end
      RUBY
    end

    @events.each { |event| deliver(event) }

    run = WorkflowRun.find_by!(run_id: @events.first["run_id"])
    assert_equal "failed", run.status
    assert_match(/FailCog/, run.error)
    step = run.workflow_steps.first
    assert_equal "failed", step.status
    assert_match(/status code 3/, step.error)
    assert run.failed?
  end

  def test_a_skipped_step_is_recorded_as_skipped
    run_workflow(<<~RUBY)
      execute do
        ruby(:nope) { skip! }
        ruby(:after) { "ran" }
      end
    RUBY
    @events.each { |event| deliver(event) }

    statuses = WorkflowRun.find_by!(run_id: @events.first["run_id"]).workflow_steps.ordered.map(&:status)
    assert_equal %w[skipped ok], statuses
  end

  # A reconnect replays retained messages; re-delivering the same events must
  # not create a second run or duplicate steps.
  def test_replaying_the_same_events_is_idempotent
    run_workflow("execute { ruby(:x) { 1 } }")
    events = @events.dup
    events.each { |event| deliver(event) }
    events.each { |event| deliver(event) }

    assert_equal 1, WorkflowRun.count
    assert_equal 1, WorkflowRun.first.workflow_steps.count
  end

  # The observer can start mid-run (it was restarted, or the run predates it):
  # a step for an unseen run must create the run rather than be dropped.
  def test_a_step_arriving_without_run_started_still_lands
    @events.clear
    deliver("run_id" => "orphan-1", "kind" => "step_finished", "workflow" => "/tmp/x.rb",
            "at" => Time.now.utc.iso8601(3), "rune" => "cmd", "name" => "ls",
            "index" => 1, "status" => "ok", "duration_ms" => 3.5, "output" => "a\n")

    run = WorkflowRun.find_by(run_id: "orphan-1")
    assert run, "an event for an unseen run must create it"
    assert_equal 1, run.workflow_steps.count
    assert_equal "ok", run.workflow_steps.first.status
  end

  def test_packets_carry_the_run_id_so_a_run_can_list_them
    run_workflow("execute { ruby(:x) { 1 } }")
    @events.each { |event| deliver(event) }

    run_id = @events.first["run_id"]
    assert_equal @events.size, Packet.where(run_id: run_id).count
    assert_equal @events.size, Packet.where(run_id: run_id).of_kind("workflow_event").count
  end
end
