# frozen_string_literal: true

require_relative "test_helper"
require_relative "../lib/runes/workflow"
require "json"

# A workflow run used to publish nothing at all, so it was invisible to the
# observatory and to anything else on the fabric (doc5.md O1.1). These tests
# pin the event contract the observer builds a run view from.
class TelemetryTest < Minitest::Test
  def setup
    @events = []
    @previous = Runes::Telemetry.sink
    @dir = Dir.mktmpdir("runes-tel-")
  end

  def teardown
    Runes::Telemetry.sink = @previous
    FileUtils.remove_entry(@dir) if @dir && Dir.exist?(@dir) && @dir.start_with?(Dir.tmpdir)
  end

  def run_workflow(source, sink: nil)
    @events.clear
    Runes::Telemetry.sink = sink || ->(event) { @events << event }
    path = File.join(@dir, "workflow.rb")
    File.write(path, source)
    Runes::Workflow.from_file(path, Runes::WorkflowParams.new)
  end

  def kinds
    @events.map { |e| e["kind"] }
  end

  def steps
    @events.select { |e| e["kind"] == "step_finished" }
  end

  def test_a_run_emits_ordered_events_under_one_run_id
    run_workflow(<<~RUBY)
      execute do
        ruby(:greeting) { "hello" }
        cmd(:echo) { "echo world" }
        ruby(:check) { cmd!(:echo).out.strip }
      end
    RUBY

    assert_equal %w[run_started step_started step_finished step_started step_finished
                    step_started step_finished run_finished], kinds
    assert_equal 1, @events.map { |e| e["run_id"] }.uniq.size,
                 "every event of a run must share one run_id"
    assert_equal [1, 2, 3], steps.map { |e| e["index"] }, "steps are numbered in run order"
    assert_equal %w[ruby cmd ruby], steps.map { |e| e["rune"] }
    assert_equal %w[greeting echo check], steps.map { |e| e["name"] }
  end

  def test_step_events_carry_status_duration_and_output
    run_workflow(<<~RUBY)
      execute do
        cmd(:echo) { "echo world" }
      end
    RUBY

    step = steps.first
    assert_equal "ok", step["status"]
    assert_operator step["duration_ms"], :>=, 0
    assert_equal "world\n", step["output"]
    assert_nil step["error"]

    run = @events.find { |e| e["kind"] == "run_finished" }
    assert_equal "ok", run["status"]
    assert_operator run["duration_ms"], :>=, 0
    assert_equal 1, run["steps"]
  end

  def test_a_failing_step_is_marked_failed_and_the_run_too
    error = assert_raises(Runes::ControlFlow::FailCog) do
      run_workflow(<<~RUBY)
        execute do
          cmd(:boom) { ["ruby", "-e", "exit 3"] }
        end
      RUBY
    end
    assert_match(/status code 3/, error.message)

    assert_equal "failed", steps.last["status"]
    assert_match(/FailCog/, steps.last["error"])
    assert_equal "failed", @events.find { |e| e["kind"] == "run_finished" }["status"]
  end

  def test_a_skipped_step_is_marked_skipped
    run_workflow(<<~RUBY)
      execute do
        ruby(:nope) { skip! }
        ruby(:after) { "ran" }
      end
    RUBY

    assert_equal %w[skipped ok], steps.map { |e| e["status"] }
  end

  # Telemetry must never be able to fail a run: a broken sink is a broken
  # observer, not a broken workflow.
  def test_a_raising_sink_does_not_break_the_run
    workflow = run_workflow("execute { ruby(:x) { 1 } }", sink: ->(_e) { raise "sink is down" })

    refute_nil workflow
    assert workflow.completed?
  end

  def test_the_transport_sink_publishes_one_topic_per_event
    published = []
    transport = Object.new
    transport.define_singleton_method(:publish) do |topic, payload, **options|
      published << [topic, JSON.parse(payload), options]
    end
    sink = Runes::Telemetry::TransportSink.new(transport: transport)

    run_workflow("execute { ruby(:x) { 1 } }", sink: sink)

    assert_equal 4, published.size
    topics = published.map(&:first)
    assert_equal 1, topics.map { |t| t.split("/")[2] }.uniq.size, "one run id across the topics"
    assert_includes topics, "runes/workflows/#{topics.first.split('/')[2]}/run_started"
    assert_includes topics, "runes/workflows/#{topics.first.split('/')[2]}/step_finished"
    assert_equal 1, published.first[2][:qos]
    assert_equal 4, sink.published
  end

  def test_long_output_is_truncated_rather_than_shipped_whole
    run_workflow(<<~RUBY)
      execute do
        ruby(:big) { "x" * 20_000 }
      end
    RUBY

    output = steps.first["output"]
    assert_operator output.bytesize, :<, 20_000
    assert_includes output, "bytes dropped"
  end
  # The run telemetry sink has the same lifetime rule as the guard's.
  def test_the_run_sink_closes_the_transport_and_is_forgotten
    transport = Object.new
    closed = []
    transport.define_singleton_method(:publish) { |*_a, **_k| true }
    transport.define_singleton_method(:disconnect) { closed << :bye }

    sink = Runes::Telemetry::TransportSink.new(transport: transport)
    sink.call("kind" => "run_started", "run_id" => "r1")
    Runes::Telemetry.sink = sink
    Runes::Telemetry.close!

    assert_nil Runes::Telemetry.sink
    assert_equal [:bye], closed
    assert sink.closed?
  end
end
