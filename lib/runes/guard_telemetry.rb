# frozen_string_literal: true

require "json"
require "time"

module Runes
  # Refusals, made visible (doc5.md O2.3).
  #
  # The observatory could always show what was *published*; what was *refused*
  # never left the process — a warning line in a log nobody keeps. That is the
  # security-relevant half: every S4-1/S4-2 class finding in the round-5 audit
  # was about refusals that did not happen, and you cannot notice a refusal
  # that did not happen if the ones that did are invisible.
  #
  # Same shape as Runes::Telemetry, deliberately: a *sink* decides what a
  # decision is worth.
  #
  #   Runes::GuardTelemetry.sink = ->(decision) { ... }
  #   Runes::GuardTelemetry.sink = Runes::GuardTelemetry::TransportSink.new(transport: t,
  #                                                                        agent_id: 'a1')
  #
  # Recording is best-effort in both directions: a sink that raises is logged
  # and swallowed, and a flood is capped, because a guard that can be turned
  # into a denial amplifier is a worse bug than a missing telemetry event.
  module GuardTelemetry
    TOPIC = 'runes/guard/denied'
    # A tool called in a loop by a hostile or confused planner must not be able
    # to fill the fabric (or the observer's database) with one denial per
    # iteration. Past the cap we count and say so once.
    MAX_PER_MINUTE = 240
    MAX_RESOURCE_BYTES = 512

    class << self
      # A callable, or nil for "no telemetry" (the default: a library user pays
      # nothing, and a plain Dispatcher attaches one for its transport).
      attr_accessor :sink

      def enabled?
        !sink.nil?
      end

      # Build a sink that publishes decisions on the fabric.
      def build_sink(spec, settings: nil, transport: nil, agent_id: nil)
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
      def attach(transport:, agent_id: nil)
        return sink if sink

        self.sink = build_sink('mqtt', transport: transport, agent_id: agent_id)
        at_exit { close! } if sink
        sink
      rescue StandardError => e
        warn "[GuardTelemetry] could not attach: #{e.class}: #{e.message}"
        nil
      end

      # One refusal: who, what, on what, and (when we know it) which rule.
      #
      # @return [Hash] the decision, so a caller can log or test it
      def record(tool:, action:, resource: nil, rule: nil, phase: 'tool', agent: nil, at: Time.now)
        decision = {
          'tool' => tool.to_s,
          'action' => action.to_s,
          'resource' => truncate(resource),
          'rule' => rule,
          'decision' => 'denied',
          'phase' => phase.to_s,
          'agent' => agent,
          'at' => at.utc.iso8601(3)
        }.compact

        emit(decision)
        decision
      end

      # Close whatever sink is installed and forget it (call before exit).
      def close!
        current = sink
        self.sink = nil
        current.respond_to?(:close) ? current.close : nil
      end

      # Test/reset seam: drop the rate-limit window (the sink is the caller's).
      def reset_window!
        @window_started = nil
        @window_count = 0
        @suppressed = 0
        @warned = false
      end

      def suppressed
        @suppressed.to_i
      end

      private

      def emit(decision)
        if capped?
          @suppressed = @suppressed.to_i + 1
          unless @warned
            @warned = true
            warn "[GuardTelemetry] more than #{MAX_PER_MINUTE} denials in a minute; " \
                 'further denials are counted but not published'
          end
          return decision
        end

        current = sink
        current&.call(decision)
        decision
      rescue StandardError => e
        warn "[GuardTelemetry] sink failed: #{e.class}: #{e.message}"
        decision
      end

      def capped?
        now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        @window_started ||= now
        if now - @window_started >= 60
          @window_started = now
          @window_count = 0
          @warned = false
        end
        @window_count = @window_count.to_i + 1
        @window_count > MAX_PER_MINUTE
      end

      def truncate(resource)
        text = resource.to_s
        return text if text.bytesize <= MAX_RESOURCE_BYTES

        "#{text.byteslice(0, MAX_RESOURCE_BYTES).to_s.scrub}…"
      end
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
        @transport.publish(TOPIC, JSON.generate(payload))
      end

      # Same lifetime rule as the run telemetry sink: close before exit, or the
      # last refusal of a process can be lost.
      def close
        @transport.disconnect
        @closed = true
      rescue StandardError
        false
      end

      def closed? = @closed == true
    end
  end
end
