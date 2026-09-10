# Turn an interaction's packets into a waterfall.
#
# The interaction page used to be a flat list of packets, which hides the only
# thing you actually want from a trace: WHERE THE TIME WENT. A packet on this
# bus is an instant, so the informative quantity is the gap between consecutive
# packets — a 30 second pause between `started` and the first `progress` is the
# planner call, and it should look like 30 seconds.
#
# Pure and side-effect free, so the arithmetic is unit-testable without a view.
class InteractionTimeline
  Span = Struct.new(:index, :from_kind, :from_event, :to_kind, :to_event, :tool,
                    :start_ms, :duration_ms, :percent, :width_percent, :label,
                    keyword_init: true)
  Marker = Struct.new(:index, :kind, :event, :tool, :at, :offset_percent, :label,
                      keyword_init: true)

  # A gap must be at least this share of the interaction before it is called
  # out as "where the time went". Deliberately not lower: in a short
  # interaction with four even gaps each one is a third of the total, and
  # naming one of them dominant would be noise dressed up as insight.
  DOMINANT_SHARE = 0.4

  class << self
    def build(packets)
      new(packets).build
    end
  end

  def initialize(packets)
    @packets = packets.sort_by(&:occurred_at)
  end

  def build
    return empty_result if @packets.empty?

    total_ms = ((@packets.last.occurred_at - @packets.first.occurred_at) * 1000).round(1)
    { spans: spans(total_ms), markers: markers(total_ms), total_ms: total_ms,
      dominant: dominant_span(total_ms), slowest_gap_ms: slowest_gap_ms }
  end

  private

  def empty_result
    { spans: [], markers: [], total_ms: 0.0, dominant: nil, slowest_gap_ms: nil }
  end

  def spans(total_ms)
    # `map.with_index`, not `with_index`: the latter returns the enumerator
    # and silently discards every span the block builds.
    @packets.each_cons(2).map.with_index do |(previous, current), index|
      duration = ((current.occurred_at - previous.occurred_at) * 1000).round(1)
      start = ((previous.occurred_at - @packets.first.occurred_at) * 1000).round(1)
      Span.new(
        index: index + 1,
        from_kind: previous.kind, from_event: previous.event,
        to_kind: current.kind, to_event: current.event, tool: current.tool,
        start_ms: start, duration_ms: duration,
        percent: total_ms.positive? ? (start / total_ms * 100).round(2) : 0.0,
        width_percent: percent_width(duration, total_ms),
        label: label_for(current)
      )
    end
  end

  def markers(total_ms)
    @packets.map.with_index do |packet, index|
      offset = ((packet.occurred_at - @packets.first.occurred_at) * 1000).round(1)
      Marker.new(index: index + 1, kind: packet.kind, event: packet.event, tool: packet.tool,
                 at: packet.occurred_at,
                 offset_percent: total_ms.positive? ? (offset / total_ms * 100).round(2) : 0.0,
                 label: label_for(packet))
    end
  end

  # The gap that explains most of the interaction: usually the LLM call or the
  # slowest tool, which is exactly what a flat list hides.
  def dominant_span(total_ms)
    return nil unless total_ms.positive?

    span = spans(total_ms).max_by(&:duration_ms)
    return nil if span.nil? || span.duration_ms < (total_ms * DOMINANT_SHARE)

    span
  end

  def slowest_gap_ms
    spans(0).map(&:duration_ms).max
  end

  def percent_width(duration, total_ms)
    return 0.0 unless total_ms.positive?

    (duration / total_ms * 100).clamp(0.0, 100.0).round(2)
  end

  # A label that names what the wait was FOR: the packet that closed the gap.
  def label_for(packet)
    parts = [packet.kind]
    parts << packet.event.to_s if packet.event.present?
    parts << packet.tool.to_s if packet.tool.present?
    parts.reject(&:empty?).join(" · ")
  end
end
