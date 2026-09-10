require "test_helper"

# The waterfall's whole point is that a 30 second pause LOOKS like 30 seconds,
# so the arithmetic that turns packets into bars is worth pinning exactly.
class InteractionTimelineTest < ActiveSupport::TestCase
  def packet(kind:, at:, event: nil, tool: nil)
    Packet.new(topic: "runes/prompts/x/#{kind}", kind: kind, event: event, tool: tool,
               payload: "{}", occurred_at: at, received_at: at)
  end

  def test_gaps_become_bars_proportional_to_the_interaction
    t0 = Time.current
    packets = [
      packet(kind: "prompt", at: t0),
      packet(kind: "started", at: t0 + 0.5),
      packet(kind: "progress", at: t0 + 10.5, event: "plan_ready"),
      packet(kind: "response", at: t0 + 11.0)
    ]

    result = InteractionTimeline.build(packets)

    assert_in_delta 11_000, result[:total_ms], 50
    assert_equal 3, result[:spans].size
    assert_equal [0.5, 10.0, 0.5].map { |s| (s * 1000).round }, result[:spans].map { |s| s.duration_ms.round }
    # the sum of the bars is the whole interaction
    assert_in_delta 100.0, result[:spans].sum(&:width_percent), 0.1
    # offsets are cumulative
    assert_in_delta 4.5, result[:spans][1].percent, 0.2
  end

  def test_the_dominant_gap_is_named
    t0 = Time.current
    result = InteractionTimeline.build([
      packet(kind: "started", at: t0),
      packet(kind: "progress", at: t0 + 30, event: "plan_ready"),
      packet(kind: "response", at: t0 + 30.2)
    ])

    dominant = result[:dominant]
    refute_nil dominant, "a 99% gap must be called out"
    assert_equal "progress · plan_ready", dominant.label
    assert_in_delta 30_000, dominant.duration_ms, 50
  end

  def test_an_evenly_spread_interaction_has_no_dominant_gap
    t0 = Time.current
    result = InteractionTimeline.build([
      packet(kind: "a", at: t0), packet(kind: "b", at: t0 + 1),
      packet(kind: "c", at: t0 + 2), packet(kind: "d", at: t0 + 3)
    ])

    assert_nil result[:dominant], "a third of the run each is not a dominating gap"
  end

  def test_a_tool_is_named_in_the_label
    t0 = Time.current
    result = InteractionTimeline.build([
      packet(kind: "progress", at: t0, event: "step_start"),
      packet(kind: "tool_response", at: t0 + 2, tool: "run_command")
    ])

    assert_equal "tool_response · run_command", result[:spans].first.label
  end

  def test_markers_exist_for_every_packet
    t0 = Time.current
    result = InteractionTimeline.build([packet(kind: "prompt", at: t0), packet(kind: "response", at: t0 + 4)])

    assert_equal 2, result[:markers].size
    assert_equal [0.0, 100.0], result[:markers].map(&:offset_percent)
  end

  # A single instantaneous packet has no duration to divide by: the timeline
  # must not divide by zero or draw a 100%-wide lie.
  def test_a_single_packet_is_handled
    result = InteractionTimeline.build([packet(kind: "prompt", at: Time.current)])

    assert_equal 0.0, result[:total_ms]
    assert_empty result[:spans]
    assert_equal 1, result[:markers].size
    assert_nil result[:dominant]
  end

  def test_an_empty_interaction_is_empty
    result = InteractionTimeline.build([])

    assert_empty result[:spans]
    assert_empty result[:markers]
    assert_nil result[:dominant]
  end
end
