# frozen_string_literal: true

# Harness half of Runes::Telemetry: the transport sink that publishes run
# events on the fabric (docs/spinel/spec-tier-c.md §C3 split). Loaded by
# lib/runes.rb; the kernel entry keeps the pure core in telemetry.rb.
require_relative 'telemetry'
require_relative 'json_facade'

module Runes
  module Telemetry
    class << self
      # Build a sink from a spec string: "mqtt"/"auto"/"1" publish on the
      # fabric, "off"/nil disable. Used by bin/runes-workflow.
      def build_sink(spec, settings: nil, transport: nil)
        value = spec.to_s.strip.downcase
        return nil if value.empty? || %w[0 false no off none].include?(value)

        require_relative 'transport' unless defined?(Runes::Transport)
        transport ||= Runes::Transport.build(kind: nil, settings: settings)
        transport.connect unless transport.connected?
        TransportSink.new(transport: transport)
      end
    end

    # Publishes each event on the fabric so anything listening — the
    # observatory, a TUI, another agent — can watch runs happen live.
    #
    #   runes/workflows/<run_id>/run_started
    #   runes/workflows/<run_id>/step_finished  ...
    class TransportSink
      PREFIX = "runes/workflows"

      attr_reader :transport, :published

      def initialize(transport:, prefix: PREFIX)
        @transport = transport
        @prefix = prefix
        @published = 0
        @mutex = Mutex.new
      end

      def call(event)
        kind = event["kind"].to_s
        run_id = event["run_id"].to_s
        return false if kind.empty? || run_id.empty?

        @transport.publish(topic(run_id, kind), Runes::Json.generate(event), qos: 1)
        @mutex.synchronize { @published += 1 }
        true
      end

      def topic(run_id, kind)
        "#{@prefix}/#{run_id}/#{kind}"
      end

      # Flush and close the transport. Whoever owns the sink's lifetime must
      # close it; `Runes::Telemetry.close!` is the convenience for that.
      def close
        @transport.disconnect
        @closed = true
      rescue StandardError
        # Closing telemetry must never raise into a caller that is finishing.
        false
      ensure
        @published ||= 0
      end

      def closed?
        @closed == true
      end
    end
  end
end
