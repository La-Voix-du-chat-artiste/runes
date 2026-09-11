class ApplicationController < ActionController::Base
  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern

  # Changes to the importmap will invalidate the etag for HTML responses
  stale_when_importmap_changes

  # Shared by controllers (stats) and views (the top-bar pill); memoized per
  # request on the same ivar the view helper used to use.
  helper_method :ingest_status, :observed_packet_count, :observed_agent_count

  private

  def ingest_status
    @ingest_status ||= IngestStatus.current
  end

  # The layout footer and the dashboard both want these totals; memoizing
  # them here removes the duplicate COUNT(*) per page (O5-7).
  def observed_packet_count
    @observed_packet_count ||= Packet.count
  end

  def observed_agent_count
    @observed_agent_count ||= Agent.count
  end

  # Packets per minute for the last N minutes, for any scope. A gap is a zero,
  # not a missing bar: "the fleet went quiet" is information, and it should
  # look like it. Shared by the dashboard (all traffic) and the security page
  # (refusals only).
  def packet_volume(scope = Packet.all, minutes: 30)
    window_start = minutes.minutes.ago.beginning_of_minute
    counts = scope.where("occurred_at >= ?", window_start)
                  .group("strftime('%Y-%m-%d %H:%M', occurred_at)").count

    (0...minutes).map do |offset|
      slot = window_start + offset.minutes
      { at: slot, count: counts[slot.strftime("%Y-%m-%d %H:%M")].to_i }
    end
  end
end
