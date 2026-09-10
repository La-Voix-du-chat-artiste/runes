# One rune execution inside a run: what ran, for how long, and what came out.
class WorkflowStep < ApplicationRecord
  STATUSES = %w[running ok skipped failed].freeze

  belongs_to :workflow_run, inverse_of: :workflow_steps

  validates :status, inclusion: { in: STATUSES }

  scope :ordered, -> { order(:position) }

  def self.duration_label(ms)
    return "—" if ms.nil?

    ms = ms.to_f
    return "#{ms.round(1)}ms" if ms < 1000
    return "#{format('%.2f', ms / 1000)}s" if ms < 60_000

    "#{(ms / 60_000.0).round(1)}m"
  end

  def duration_label
    self.class.duration_label(duration_ms)
  end

  def running? = status == "running"
  def failed? = status == "failed"
  def skipped? = status == "skipped"
  def ok? = status == "ok"

  # The pill class the timeline and the step list share, so a status is the
  # same colour everywhere it appears.
  def pill_class
    case status
    when "ok" then "online"
    when "skipped" then "stale"
    else "offline"
    end
  end

  def display_name
    name.presence || "(anonymous)"
  end

  def label
    scope.present? ? "#{scope}.#{display_name}" : display_name
  end

  # Offset from the run's start, as a percentage of the run, for the waterfall.
  def offset_percent
    run = workflow_run
    return 0.0 unless run&.started_at && started_at

    ((started_at - run.started_at) * 1000 / run.timeline_window_ms * 100).clamp(0.0, 100.0)
  end

  def width_percent
    run = workflow_run
    return 1.0 unless run

    ((duration_ms.to_f / run.timeline_window_ms) * 100).clamp(0.6, 100.0)
  end

  def output_preview(limit = 240)
    text = output.to_s.strip
    return nil if text.empty?

    text.length > limit ? "#{text[0, limit]}…" : text
  end
end
