# doc5.md O1.5 — an "abnormal" event the app can show and an operator can
# acknowledge. Detectors upsert through .record, which dedupes by
# (kind, subject): a flapping agent is one row with a count, not a flood.
class Alert < ApplicationRecord
  SEVERITIES = %w[info warn error].freeze

  validates :kind, :subject, presence: true
  validates :severity, inclusion: { in: SEVERITIES }
  validates :count, numericality: { greater_than: 0 }

  scope :unacknowledged, -> { where(acknowledged: false) }
  scope :recent_first, -> { order(last_seen_at: :desc) }

  # Upsert occurrences. `increment:` is how many occurrences this call
  # represents (detectors batch by group); defaults to one per call.
  def self.record(kind:, subject:, severity: "warn", details: nil, at: Time.current, increment: 1)
    alert = find_or_initialize_by(kind: kind.to_s, subject: subject.to_s)
    alert.severity = severity.to_s
    alert.details = details if details
    alert.first_seen_at ||= at
    alert.last_seen_at = at
    alert.count = alert.new_record? ? increment.to_i : alert.count + increment.to_i
    alert.save!
    alert
  end

  def acknowledge!
    update!(acknowledged: true)
  end
end
