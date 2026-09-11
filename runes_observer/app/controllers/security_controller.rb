# What was *refused*, next to the dashboard's "who published what"
# (doc5.md O2.3).
#
# The observatory could always show what travelled on the fabric. A capability
# guard's refusals never left the process, which is the security-relevant half:
# you cannot notice a refusal that did not happen if the ones that did are
# invisible. This page is read-only like the rest of the app — it reports,
# it does not block.
class SecurityController < ApplicationController
  DENIAL_KIND = "guard_denied"
  WINDOW = 24.hours
  TOP = 8

  def show
    @window = WINDOW
    @denials = Packet.where(kind: DENIAL_KIND).where("occurred_at >= ?", WINDOW.ago)
    @denials_last_hour = @denials.where("occurred_at >= ?", 1.hour.ago)
    @by_tool = top(@denials, :tool)
    @by_agent = top(@denials, :agent_id)
    @by_action = top(@denials, :event)
    @recent = filtered.limit(60).to_a
    @volume = packet_volume(@denials, minutes: 30)
    @all_time = Packet.where(kind: DENIAL_KIND).count

    # Signature state (O0.3) lives on the same page: who published, and what
    # was blocked, are the two halves of one question.
    @signature_counts = Packet.since(1.hour.ago).group(:signature_state).count
    @impersonations = ImpersonationDetector.call
    @require_signatures = ObserverSignature.require_signatures?
    @unsigned_recent = Packet.since(1.hour.ago).where(signature_state: %w[unsigned]).count

    # Filter options come from the data, so the page never offers a dead filter.
    @tools = Packet.where(kind: DENIAL_KIND).where.not(tool: nil).distinct.order(:tool).pluck(:tool)
    @agents = Packet.where(kind: DENIAL_KIND).where.not(agent_id: nil).distinct.order(:agent_id).pluck(:agent_id)
  end

  private

  def filtered
    scope = @denials.recent
    scope = scope.where(tool: params[:tool]) if params[:tool].present?
    scope = scope.where(agent_id: params[:agent_id]) if params[:agent_id].present?
    scope = scope.where(event: params[:denied_action]) if params[:action_name].present?
    scope
  end

  def top(scope, column)
    scope.where.not(column => nil).group(column).count.sort_by { |_value, count| -count }.first(TOP)
  end
end
