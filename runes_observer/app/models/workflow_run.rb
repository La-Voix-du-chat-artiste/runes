# One workflow run, rebuilt from its telemetry events.
#
# The engine emits run_started / step_started / step_finished / run_finished on
# `runes/workflows/<run_id>/<kind>`; the projector folds them into this row and
# its steps, so the observatory can show a run as a timeline instead of asking
# you to read a packet feed.
class WorkflowRun < ApplicationRecord
  STATUSES = %w[running ok failed timeout].freeze

  has_many :workflow_steps, -> { order(:position) }, dependent: :destroy, inverse_of: :workflow_run

  validates :run_id, presence: true, uniqueness: true
  validates :status, inclusion: { in: STATUSES }

  scope :recent, -> { order(started_at: :desc, id: :desc) }
  scope :finished, -> { where.not(finished_at: nil) }

  def to_param
    run_id
  end

  def running?
    status == "running"
  end

  def failed?
    status == "failed" || status == "timeout"
  end

  def finished?
    !finished_at.nil?
  end

  def duration_label
    WorkflowStep.duration_label(duration_ms || live_duration_ms)
  end

  # A run that is still going has no recorded duration yet.
  def live_duration_ms
    return nil unless started_at

    ((finished_at || Time.current) - started_at) * 1000
  end

  def workflow_name
    File.basename(workflow.to_s)
  end

  def params_hash
    params.to_s.empty? ? {} : JSON.parse(params)
  rescue JSON::ParserError
    {}
  end

  # "12.3s" — the timeline header.
  def started_label
    started_at&.strftime("%H:%M:%S") || "—"
  end

  # Consumed by the timeline: every step's own bar window, plus the tallest
  # stack, so rows can be positioned as a percentage of the whole run.
  def timeline_window_ms
    return 1.0 if duration_ms.to_i <= 0

    duration_ms.to_f
  end
end
