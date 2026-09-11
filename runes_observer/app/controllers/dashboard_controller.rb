class DashboardController < ApplicationController
  def index
    @status = ingest_status
    @online = Agent.online.by_activity.to_a
    @ended = Agent.ended.by_activity.limit(25).to_a
    @recent = Packet.recent.limit(80).to_a
    @runs = WorkflowRun.recent.limit(6).includes(:workflow_steps).to_a
    @run_stats = {
      total: WorkflowRun.count,
      failed: WorkflowRun.where(status: %w[failed timeout]).count
    }
    @last_id = @recent.map(&:id).max || 0
    @top_kinds = Packet.group(:kind).count.sort_by { |_kind, count| -count }.first(8).to_h
    @volume = packet_volume(minutes: 30)
    @volume_total = @volume.sum { |slot| slot[:count] }
    @kind_mix = kind_mix
    # Who published, and does anything back it (doc5.md O0.3)?
    @signature_counts = Packet.since(1.hour.ago).group(:signature_state).count
    @impersonations = ImpersonationDetector.call
    @require_signatures = ObserverSignature.require_signatures?
    @unsigned_recent = Packet.since(1.hour.ago).where(signature_state: %w[unsigned]).count
    @stats = {
      online: @online.size,
      ended: Agent.ended.count,
      unknown: Agent.where(state: "unknown").count,
      total_packets: observed_packet_count,
      last_5m: Packet.since(5.minutes.ago).count
    }
  end

  private

  # Packets per minute for the last N minutes. A gap is a zero, not a missing
  # bar: "the fleet went quiet" is information, and it should look like it.
  def packet_volume(minutes:)
    window_start = minutes.minutes.ago.beginning_of_minute
    counts = Packet.where("occurred_at >= ?", window_start)
                   .group("strftime('%Y-%m-%d %H:%M', occurred_at)").count

    (0...minutes).map do |offset|
      slot = window_start + offset.minutes
      { at: slot, count: counts[slot.strftime("%Y-%m-%d %H:%M")].to_i }
    end
  end

  # The mix over the last hour, as shares, so the panel answers "what is this
  # bus actually carrying?" rather than only "how much".
  def kind_mix
    total = Packet.since(1.hour.ago).count
    return [] if total.zero?

    Packet.since(1.hour.ago).group(:kind).count
          .sort_by { |_kind, count| -count }.first(6)
          .map { |kind, count| { kind: kind, count: count, percent: (count.to_f / total * 100).round(1) } }
  end
end
