# Singleton row describing the ingest process (the MQTT subscriber).
#
# The web process cannot see the ingest process's memory, so the ingest
# publishes its own state here: connected/disconnected, last error and the
# total packet count. The dashboard reads it to answer "is the observer
# actually watching the bus?".
#
# Every writer swallows and logs its own failure: they are called from the
# ingest's rescue/ensure path, so raising here would kill the process that is
# trying to report a problem.
class IngestStatus < ApplicationRecord
  SINGLETON_ID = 1

  # Connected, but nothing has been heard for this long: the process is
  # almost certainly dead, and must not read as "connected".
  DEAD_AFTER = 2.minutes
  WATCHING_WITHIN = 30.seconds

  def self.current
    where(id: SINGLETON_ID).first_or_create!(host: default_host, port: default_port)
  rescue ActiveRecord::RecordNotUnique
    # Two requests can race the first insert; the loser re-reads the winner.
    where(id: SINGLETON_ID).first
  end

  def self.default_host
    ENV.fetch("RUNES_MQTT_HOST", "127.0.0.1")
  end

  def self.default_port
    ENV.fetch("RUNES_MQTT_PORT", "1883").to_i
  end

  def self.mark_connected!(host:, port:, transport: nil)
    status = current
    status.update!(connected: true, host: host, port: port, last_error: nil,
                   started_at: Time.current,
                   transport: transport.presence || status.transport)
    status
  rescue StandardError => e
    warn_failure("mark_connected!", e)
    nil
  end

  def self.mark_disconnected!(error = nil)
    status = current
    status.update!(connected: false, last_error: error.to_s[0, 500])
    status
  rescue StandardError => e
    warn_failure("mark_disconnected!", e)
    nil
  end

  def self.bump!(at: Time.current, by: 1, lag_ms: nil)
    status = current
    changes = { last_message_at: at,
                packets_total: status.packets_total.to_i + by.to_i,
                updated_at: Time.current }
    changes[:last_lag_ms] = lag_ms.to_i if lag_ms
    status.update_columns(changes)
    status
  rescue StandardError => e
    warn_failure("bump!", e)
    nil
  end

  # One more transport rebuild. A climbing number here is the difference
  # between "connected" and "connected *reliably*".
  def self.bump_reconnects!(by: 1)
    status = current
    status.update_columns(reconnects: status.reconnects.to_i + by.to_i,
                          updated_at: Time.current)
    status
  rescue StandardError => e
    warn_failure("bump_reconnects!", e)
    nil
  end

  # A message the ingest could not store: visible loss, not silent loss.
  def self.bump_dropped!(by: 1)
    status = current
    status.update_columns(packets_dropped: status.packets_dropped.to_i + by.to_i,
                          updated_at: Time.current)
    status
  rescue StandardError => e
    warn_failure("bump_dropped!", e)
    nil
  end

  def self.warn_failure(operation, error)
    Rails.logger.warn("[observer] IngestStatus.#{operation} failed: #{error.class}: #{error.message}")
  end
  private_class_method :warn_failure

  def last_message_age
    return nil if last_message_at.blank?

    Time.current - last_message_at
  end

  def watching?
    connected? && last_message_age.present? && last_message_age < WATCHING_WITHIN
  end

  # The most recent proof of life, in order of preference.
  def liveness_at
    last_message_at || started_at || updated_at
  end

  # Connected, but the clock stopped moving: the ingest was killed (or is
  # wedged) without a clean disconnect.
  def dead?
    return false unless connected?
    return false if liveness_at.blank?

    Time.current - liveness_at > DEAD_AFTER
  end

  def display_state
    return "no data" if last_message_at.blank? && !connected?
    return "dead" if dead?
    return "watching" if watching?

    connected? ? "connected" : "disconnected"
  end

  # The fabric's throughput as stored, not as counted by the ingest: derived
  # from the packets table so a reconnect (which resets started_at) or a
  # restarted process cannot inflate it.
  def packets_per_minute(window: 5.minutes)
    Packet.where("occurred_at >= ?", window.ago).count / (window / 60.0)
  end

  def lag_label
    return "unknown (publisher sent no clock)" if last_lag_ms.nil?

    ms = last_lag_ms.to_i
    return "#{ms} ms" if ms < 1_000

    "#{(ms / 1000.0).round(1)} s"
  end

  # A lag an operator should look at: the newest packet's own clock is far
  # behind our receipt of it.
  LAG_WARN_MS = 30_000

  def lagging?
    last_lag_ms.to_i > LAG_WARN_MS
  end
end
