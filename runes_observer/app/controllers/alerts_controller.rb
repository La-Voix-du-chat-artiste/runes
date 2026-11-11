# doc5.md O1.5 — the alert list and the ack. Read-only except the ack, which
# is the one write an operator makes ("I have seen this").
class AlertsController < ApplicationController
  def index
    # Re-run the detectors over recent packets so the page is live even
    # between ingest batches.
    AlertDetector.call(scope: Packet.since(24.hours.ago))
    @alerts = Alert.recent_first.limit(100).to_a
    @unacked = Alert.unacknowledged.count
  end

  def ack
    alert = Alert.find(params[:id])
    alert.acknowledge!
    redirect_to alerts_path, notice: "Acknowledged #{alert.kind} on #{alert.subject}"
  end
end
