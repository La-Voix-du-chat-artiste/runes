# Workflow runs, as a timeline rather than a packet feed.
#
# The engine's telemetry (runes/workflows/<run_id>/…) is projected into
# WorkflowRun + WorkflowStep by WorkflowRunProjector, so this controller only
# reads what is already there.
class RunsController < ApplicationController
  PER_PAGE = 50
  PACKETS_SHOWN = 200

  def index
    @runs = filtered.recent.limit(PER_PAGE).includes(:workflow_steps).to_a
    @statuses = WorkflowRun::STATUSES
    @workflows = WorkflowRun.distinct.order(:workflow).pluck(:workflow)
    @stats = {
      total: filtered.count,
      running: filtered.where(status: "running").count,
      ok: filtered.where(status: "ok").count,
      failed: filtered.where(status: %w[failed timeout]).count,
      slowest: filtered.maximum(:duration_ms)
    }
    # A shared scale so the duration bars in the table are comparable.
    @slowest = [@stats[:slowest].to_f, 1.0].max
  end

  def show
    @run = WorkflowRun.find_by!(run_id: params[:run_id])
    @steps = @run.workflow_steps.ordered.to_a
    @packets = Packet.where(run_id: @run.run_id).chronological.limit(PACKETS_SHOWN).to_a
    @params = @run.params_hash
    @failed_steps = @steps.count(&:failed?)
    @longest_step = @steps.max_by { |s| s.duration_ms.to_f }
  end

  private

  def filtered
    scope = WorkflowRun.all
    scope = scope.where(status: params[:status]) if params[:status].present?
    scope = scope.where(workflow: params[:workflow]) if params[:workflow].present?
    if params[:q].present?
      needle = "%#{params[:q].to_s.strip}%"
      scope = scope.where("workflow LIKE ? OR run_id LIKE ?", needle, needle)
    end
    scope
  end
end
