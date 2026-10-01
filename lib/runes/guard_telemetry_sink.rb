# frozen_string_literal: true

# Harness-only half of Runes::GuardTelemetry: the sink that publishes
# refusals on `runes/guard/denied`. Kept out of the Spinel kernel (it needs
# the transport + JSON payload emission); the pure recording core lives in
# guard_telemetry.rb and is what kernel users inject into
# (`Runes::GuardTelemetry.sink =`).
#
# This file also wires the CRuby JSON backend: the sink is harness-only, and
# a harness process may not have loaded lib/runes.rb (bin/runes-workflow is
# one) — without a backend the first publish would die on the facade.
require_relative 'guard_telemetry'
require_relative 'json_facade'
require_relative 'backends/cruby'

module Runes
  module GuardTelemetry
    # Build a sink from a spec string ('mqtt', '0'/'off'/'' => nil) or return
    # nil when telemetry is disabled.
    def self.build_sink(spec, settings: nil, transport: nil, agent_id: nil)
      value = spec.to_s.strip.downcase
      return nil if value.empty? || %w[0 false no off none].include?(value)

      require_relative 'transport' unless defined?(Runes::Transport)
      transport ||= Runes::Transport.build(kind: nil, settings: settings)
      transport.connect unless transport.connected?
      TransportSink.new(transport: transport, agent_id: agent_id)
    end

    # Attach a transport sink unless someone already chose one. Returns the
    # sink in use, so a caller can report what it attached.
    #
    # Whoever attaches a sink owns its lifetime, so this registers the close:
    # a sink that is never closed loses its last events. A sink that was
    # already installed is left alone — it is not ours to close.
    def self.attach(transport:, agent_id: nil)
      return sink if sink

      self.sink = build_sink('mqtt', transport: transport, agent_id: agent_id)
      at_exit { close! } if sink
      sink
    rescue StandardError => e
      warn "[GuardTelemetry] could not attach: #{e.class}: #{e.message}"
      nil
    end

    # What an observer needs: the decision as JSON on `runes/guard/denied`.
    class TransportSink
      attr_accessor :agent_id

      def initialize(transport:, agent_id: nil)
        @transport = transport
        @agent_id = agent_id
      end

      def call(decision)
        payload = agent_id ? decision.merge('agent' => decision['agent'] || agent_id) : decision
        @transport.publish(TOPIC, Runes::Json.generate(payload))
      end

      # Same lifetime rule as the run telemetry sink: close before exit, or the
      # last refusal of a process can be lost.
      def close
        @transport.disconnect
        @closed = true
      rescue StandardError
        false
      end

      def closed?
        @closed == true
      end
    end
  end
end
