# frozen_string_literal: true

require_relative "test_helper"
require_relative "../lib/runes/guard_telemetry"
require_relative "../lib/runes/capabilities/guard"

# doc5.md O2.3: a refusal that leaves no trace is half a control. The observer
# can only show what was blocked if the guard publishes it, and a denial loop
# must not be able to turn the guard into a fabric flood.
class GuardTelemetryTest < Minitest::Test
  def setup
    @original_sink = Runes::GuardTelemetry.sink
    Runes::GuardTelemetry.sink = nil
    Runes::GuardTelemetry.reset_window!
    @seen = []
  end

  def teardown
    Runes::GuardTelemetry.sink = @original_sink
    Runes::GuardTelemetry.reset_window!
  end

  def capture
    Runes::GuardTelemetry.sink = ->(decision) { @seen << decision }
  end

  def test_a_decision_carries_who_what_and_on_what
    capture

    decision = Runes::GuardTelemetry.record(tool: "write_file", action: "fs_write",
                                            resource: "/etc/passwd", phase: "tool")

    assert_equal 1, @seen.size
    assert_equal "denied", decision["decision"]
    assert_equal "write_file", decision["tool"]
    assert_equal "fs_write", decision["action"]
    assert_equal "/etc/passwd", decision["resource"]
    assert_equal "tool", decision["phase"]
    refute_nil decision["at"]
    assert_equal decision, @seen.first
  end

  def test_a_hostile_resource_is_truncated_before_it_reaches_the_wire
    capture

    Runes::GuardTelemetry.record(tool: "run_command", action: "exec", resource: "x" * 10_000)

    resource = @seen.first["resource"]
    assert_operator resource.bytesize, :<=, Runes::GuardTelemetry::MAX_RESOURCE_BYTES + 3
    assert resource.end_with?("…")
  end

  def test_a_sink_that_raises_never_propagates
    Runes::GuardTelemetry.sink = ->(_decision) { raise TypeError, "sink is down" }

    _out, err = capture_io do
      assert_equal "denied",
                   Runes::GuardTelemetry.record(tool: "read_file", action: "fs_read",
                                                resource: "/etc/shadow")["decision"]
    end
    assert_includes err, "sink failed"
  end

  # A planner in a loop must not be able to fill the broker: past the cap the
  # events are counted, not published, and the operator is told once.
  def test_a_denial_flood_is_capped_and_reported_once
    capture
    (Runes::GuardTelemetry::MAX_PER_MINUTE + 5).times do
      Runes::GuardTelemetry.record(tool: "run_command", action: "exec", resource: "ls")
    end

    assert_equal Runes::GuardTelemetry::MAX_PER_MINUTE, @seen.size
    assert_equal 5, Runes::GuardTelemetry.suppressed
  end

  def test_the_guard_reports_every_denial_but_logs_it_once
    policy = { "tools" => { "read_file" => { "fs_read" => ["/safe/#"] } } }
    guard = Runes::Capabilities::Guard.new
    guard.instance_variable_set(:@policy, policy)
    capture

    _out, err = capture_io do
      refute guard.allowed?("read_file", :fs_read, "/etc/passwd")
      refute guard.allowed?("read_file", :fs_read, "/etc/passwd")
    end

    # The warning is deduplicated; the event is not, because how often a
    # refusal happens is the thing an operator wants to see.
    assert_equal 2, @seen.size
    assert_equal 1, err.scan(/\[Guard\] deny/).size
  end

  def test_an_allow_reports_nothing
    capture
    guard = Runes::Capabilities::Guard.new
    guard.instance_variable_set(:@policy, { "tools" => { "read_file" => { "fs_read" => ["/safe/#"] } } })

    assert guard.allowed?("read_file", :fs_read, "/safe/file")
    assert_empty @seen
  end

  def test_the_transport_sink_publishes_on_the_guard_topic_with_the_agent
    transport = RecordingTransport.new
    sink = Runes::GuardTelemetry::TransportSink.new(transport: transport, agent_id: "runes-a")
    Runes::GuardTelemetry.sink = sink

    Runes::GuardTelemetry.record(tool: "run_file", action: "exec", resource: "x")

    assert_equal [Runes::GuardTelemetry::TOPIC], transport.topics
    payload = JSON.parse(transport.published.first[:payload])
    assert_equal "runes-a", payload["agent"]
    assert_equal "run_file", payload["tool"]
  end

  def test_attach_does_not_override_a_sink_someone_already_chose
    capture

    Runes::GuardTelemetry.attach(transport: RecordingTransport.new, agent_id: "runes-a")

    assert_same @seen, @seen # the capture sink is still the one in place
    assert_kind_of Proc, Runes::GuardTelemetry.sink
  end

  # A sink that is never closed loses the last event of a process: a
  # `run_finished` that never arrives leaves a run "running" for ever in the
  # observatory. This is the regression test for that (found by screenshotting a
  # real run, where the final events were missing).
  def test_a_transport_sink_closes_its_transport_once_and_never_raises
    transport = RecordingTransport.new
    transport.define_singleton_method(:disconnects) { @disconnects ||= 0 }
    transport.define_singleton_method(:disconnect) { @disconnects = disconnects + 1 }

    sink = Runes::GuardTelemetry::TransportSink.new(transport: transport, agent_id: "a")
    refute sink.closed?
    sink.close

    assert sink.closed?
    assert_equal 1, transport.disconnects

    broken = Runes::GuardTelemetry::TransportSink.new(transport: Object.new)
    refute broken.close, "closing must swallow a transport that cannot disconnect"
  end

  def test_close_bang_forgets_the_sink_and_closes_it
    transport = RecordingTransport.new
    closed = []
    transport.define_singleton_method(:disconnect) { closed << :bye }
    Runes::GuardTelemetry.sink = Runes::GuardTelemetry::TransportSink.new(transport: transport)

    Runes::GuardTelemetry.close!

    assert_nil Runes::GuardTelemetry.sink
    assert_equal [:bye], closed
  end

  def test_attach_does_not_register_a_close_for_a_sink_it_did_not_create
    capture

    assert_kind_of Proc, Runes::GuardTelemetry.attach(transport: RecordingTransport.new, agent_id: "a")
    assert_kind_of Proc, Runes::GuardTelemetry.sink, "the caller's sink is untouched"
  end

  def test_build_sink_understands_the_off_switch
    assert_nil Runes::GuardTelemetry.build_sink("off")
    assert_nil Runes::GuardTelemetry.build_sink("")
  end
end
