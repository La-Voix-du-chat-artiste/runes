# frozen_string_literal: true

# Best-effort one-shot publisher for the WEB process: the ingest owns the
# long-lived subscription, but write actions from the UI (document uploaded,
# plan requested, card moved) must announce themselves on the fabric so the
# feed, the board and the agents see them. This keeps one lazy, mutex-guarded
# Runes::Transport connection and publishes through it; any failure drops the
# connection and returns false — a missing broker must never 500 an HTTP
# request, the packet simply does not appear on the bus.
#
# `RUNES_OBSERVER_PUBLISH=off` disables publishing entirely (tests, read-only
# deployments). Transport/host/port come from the same env the ingest uses
# (RUNES_TRANSPORT / RUNES_MQTT_HOST / RUNES_MQTT_PORT), so the observer
# publishes onto the broker it watches.
class FabricPublisher
  class << self
    def enabled?
      ENV.fetch("RUNES_OBSERVER_PUBLISH", "on").casecmp("off").nonzero? && defined?(Runes::Transport) ? true : false
    end

    # @return [Boolean] true when the publish reached the transport
    def publish(topic, payload, retain: false)
      return false unless enabled?

      body = payload.is_a?(String) ? payload : JSON.generate(payload)
      mutex.synchronize do
        transport.publish(topic.to_s, body, retain: retain)
        true
      end
    rescue StandardError => e
      drop_connection
      Rails.logger.warn("[observer] publish to #{topic} failed: #{e.class}: #{e.message}")
      false
    end

    def transport
      @transport ||= begin
        t = Runes::Transport.build(
          kind: ENV["RUNES_TRANSPORT"].presence,
          host: ENV["RUNES_MQTT_HOST"].presence,
          port: ENV["RUNES_MQTT_PORT"].presence&.to_i,
          client_id: "runes-observer-pub-#{Process.pid}"
        )
        t.connect
        t
      end
    end

    def drop_connection
      mutex.synchronize do
        begin
          @transport&.disconnect
        rescue StandardError
          nil
        end
        @transport = nil
      end
    end

    # Tests swap transports (inproc hub) or disable publishing.
    def reset!
      drop_connection
    end

    private

    def mutex
      @mutex ||= Mutex.new
    end
  end
end
