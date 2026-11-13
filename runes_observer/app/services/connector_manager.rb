# frozen_string_literal: true

# Named MQTT connector profiles (docs/WORKSPACE_PLAN.md slice 2B).
#
# One broker per observer stays the rule (OBSERVATORY_ROADMAP.md §6: no
# multi-broker federation — IngestStatus is a singleton and the topic grammar
# assumes one bus), so a connector is a *profile*: Test probes it (a short
# connection that reads retained Agent Cards), Activate makes it the one the
# ingest subscribes through by bumping ingest_statuses.connector_epoch, which
# FabricIngest polls and rebuilds on. With no active row, everything falls
# back to the RUNES_MQTT_* env vars exactly as before this feature existed.
class ConnectorManager
  # Read at call time so tests (and operators via env) can tune it.
  def self.probe_seconds
    ENV.fetch("RUNES_CONNECTOR_PROBE_SECONDS", "5").to_f
  end

  A2A_DISCOVERY = "$a2a/v1/discovery/#"

  class << self
    # nil when no connector row is active — callers then use their env/constructor
    # defaults. Otherwise the settings hash for Runes::Transport.build.
    def active_settings
      connector = Connector.active.order(:id).first
      return nil unless connector

      settings = {
        host: connector.host,
        port: connector.port,
        kind: connector.transport.presence,
        client_id: connector.client_id.presence || "runes-observer-#{Process.pid}"
      }
      settings[:tls] = true if connector.tls
      if connector.username.present?
        settings[:username] = connector.username
        password = connector.password_env.present? ? ENV[connector.password_env] : nil
        settings[:password] = password if password
      end
      settings
    end

    # Flip the active connector and bump the epoch so a running ingest
    # rebuilds its transport. Transactional: exactly one active row afterwards.
    def activate!(connector)
      Connector.transaction do
        Connector.where(active: true).where.not(id: connector.id).update_all(active: false)
        connector.update!(active: true)
        status = IngestStatus.current
        status.update!(connector_epoch: status.connector_epoch + 1)
      end
      connector
    end

    # A probe is a short-lived connection that reads retained Agent Cards —
    # it never subscribes to work and never records packets. Returns
    # { state: "ok"|"error", cards:, detail: } and persists it on the row.
    def probe(connector, seconds: nil)
      result = probe_once(connector, seconds || probe_seconds)
      connector.update!(
        last_probe_at: Time.current,
        last_probe_state: result[:state],
        last_probe_detail: result[:detail]
      )
      result
    rescue StandardError => e
      connector.update!(
        last_probe_at: Time.current,
        last_probe_state: "error",
        last_probe_detail: "#{e.class}: #{e.message}"
      )
      { state: "error", cards: 0, detail: "#{e.class}: #{e.message}" }
    end

    private

    def probe_once(connector, seconds)
      raise "Runes::Transport is not loaded" unless defined?(Runes::Transport)

      settings = {
        host: connector.host, port: connector.port, kind: connector.transport.presence,
        client_id: "runes-observer-probe-#{Process.pid}"
      }
      settings[:tls] = true if connector.tls
      if connector.username.present?
        settings[:username] = connector.username
        password = connector.password_env.present? ? ENV[connector.password_env] : nil
        settings[:password] = password if password
      end

      transport = Runes::Transport.build(**settings)
      transport.connect
      cards = Queue.new
      transport.subscribe(A2A_DISCOVERY) { |_msg| cards << true }
      sleep seconds
      transport.disconnect
      { state: "ok", cards: cards.size, detail: "#{cards.size} retained agent card(s) in #{seconds}s" }
    rescue StandardError => e
      { state: "error", cards: 0, detail: "#{e.class}: #{e.message}" }
    end
  end
end
