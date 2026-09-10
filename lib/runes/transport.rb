require_relative "transport/base"
require_relative "transport/in_process"
# The classic 3.1.1 adapter is loaded on demand, like the MQTT 5 one: it
# needs the `mqtt` gem, and this file's whole promise is that MQTT is a
# choice. Eagerly requiring it made `require "runes/transport"` raise
# LoadError in any embed without that gem — half the module got defined and
# `Transport.build` never did, which is a spectacularly confusing failure.
# `lib/runes.rb` still loads it up front for the harness itself (guarded),
# so `Runes::Transport::MQTT311` keeps working for anything that requires
# the harness as a whole.

module Runes
  # Pluggable messaging. The harness talks to Runes::Transport::Base only,
  # so MQTT is a choice, not a requirement:
  #
  #   inproc  — process-local hub (tests, offline demos, embeds); supports
  #             shared groups and properties
  #   mqtt311 — classic `mqtt` gem; maximum compatibility, no groups
  #   mqtt5   — MQTT 5 with shared subscriptions + PUBLISH properties
  #   auto    — mqtt5 if the broker takes it, else mqtt311, else inproc
  module Transport
    KINDS = %w[inproc mqtt311 mqtt5 auto].freeze

    class << self
      # @param kind [String, nil] inproc|mqtt311|mqtt5|auto (RUNES_TRANSPORT)
      # @param settings [Runes::Core::Settings, nil] for env lookup
      def build(kind: nil, settings: nil, **options)
        kind = (kind || settings&.env("RUNES_TRANSPORT") || "auto").to_s.strip.downcase
        case kind
        when "inproc", "in_process", "memory", "null"
          InProcess.new(**options)
        when "mqtt311", "mqtt", "mqtt3"
          require_relative "transport/mqtt311"
          MQTT311.new(**mqtt_options(settings, options))
        when "mqtt5"
          require_relative "transport/mqtt5"
          MQTT5.new(**mqtt_options(settings, options))
        when "auto"
          auto(settings: settings, **options)
        else
          raise Error, "unknown transport #{kind.inspect} (expected one of #{KINDS.join(', ')})"
        end
      end

      # Try MQTT 5 first (it is the only thing that makes multi-agent
      # dispatch safe), fall back to 3.1.1, then to the in-process hub.
      def auto(settings: nil, logger: nil, **options)
        errors = []

        begin
          require_relative "transport/mqtt5"
          transport = MQTT5.new(**mqtt_options(settings, options))
          transport.connect
          logger&.info("transport: mqtt5 (#{transport.host}:#{transport.port}, shared subscriptions)")
          return transport
        rescue Unsupported, Error, LoadError, StandardError => e
          errors << "mqtt5: #{e.message}"
        end

        begin
          require_relative "transport/mqtt311"
          transport = MQTT311.new(**mqtt_options(settings, options))
          transport.connect
          logger&.info("transport: mqtt311 (#{transport.host}:#{transport.port}, no shared subscriptions)")
          return transport
        rescue Error, LoadError, StandardError => e
          errors << "mqtt311: #{e.message}"
        end

        logger&.warn("transport: falling back to inproc — #{errors.join('; ')}")
        transport = InProcess.new(**options)
        transport.connect
        transport
      end

      def mqtt_options(settings, options)
        {
          host: options[:host] || settings&.env("RUNES_MQTT_HOST") || "127.0.0.1",
          port: (options[:port] || settings&.env("RUNES_MQTT_PORT") || 1883).to_i,
          client_id: options[:client_id],
          will: options[:will]
        }.compact.merge(options.except(:host, :port, :client_id, :will))
      end
    end
  end
end
