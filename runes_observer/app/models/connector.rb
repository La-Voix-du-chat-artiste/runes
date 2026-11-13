# frozen_string_literal: true

# A named MQTT broker profile (docs/WORKSPACE_PLAN.md slice 2B). At most one
# row is active; the active one is what the ingest process subscribes through
# (when no row is active, the ingest falls back to the RUNES_MQTT_* env vars,
# so a fresh install behaves exactly as before connectors existed).
class Connector < ApplicationRecord
  TRANSPORTS = %w[auto mqtt5 mqtt311 inproc].freeze

  validates :name, presence: true, uniqueness: true
  validates :host, presence: true
  validates :port, numericality: { only_integer: true, in: 1..65_535 }
  validates :transport, inclusion: { in: TRANSPORTS }

  scope :active, -> { where(active: true) }

  def probe_label
    return "never probed" if last_probe_at.nil?

    "#{last_probe_state.presence || 'unknown'} · #{last_probe_at.strftime('%H:%M:%S')}"
  end
end
