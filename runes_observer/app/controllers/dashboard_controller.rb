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
    @stats = {
      online: @online.size,
      ended: Agent.ended.count,
      unknown: Agent.where(state: "unknown").count,
      total_packets: observed_packet_count,
      last_5m: Packet.since(5.minutes.ago).count
    }
  end
end
