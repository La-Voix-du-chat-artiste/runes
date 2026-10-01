# frozen_string_literal: true

require_relative 'compat'

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
  #
  # Recording is best-effort in both directions: a sink that raises is logged
  # and swallowed, and a flood is capped, because a guard that can be turned
  # into a denial amplifier is a worse bug than a missing telemetry event.
  #
  # This file is the PURE CORE (kernel subset): recording, the rate cap, and
  # sink injection. The transport sink that publishes decisions on
  # `runes/guard/denied` lives in guard_telemetry_sink.rb (harness only) —
  # the split keeps the kernel free of transport dependencies.
  module GuardTelemetry
    TOPIC = 'runes/guard/denied'
    # A tool called in a loop by a hostile or confused planner must not be able
    # to fill the fabric (or the observer's database) with one denial per
    # iteration. Past the cap we count and say so once.
    MAX_PER_MINUTE = 240
    MAX_RESOURCE_BYTES = 512

    # A callable, or nil for "no telemetry" (the default: a library user pays
    # nothing, and a plain Dispatcher attaches one for its transport).
    def self.sink
      @sink
    end

    def self.sink=(callable)
      @sink = callable
    end

    def self.enabled?
      !@sink.nil?
    end

    # Close whatever sink is installed and forget it (call before exit).
    def self.close!
      current = @sink
      @sink = nil
      current.respond_to?(:close) ? current.close : nil
    end

    # Test/reset seam: drop the rate-limit window (the sink is the caller's).
    def self.reset_window!
      @window_started = nil
      @window_count = 0
      @suppressed = 0
      @warned = false
    end

    def self.suppressed
      @suppressed.to_i
    end

    # One refusal: who, what, on what, and (when we know it) which rule.
    #
    # @return [Hash] the decision, so a caller can log or test it
    def self.record(tool:, action:, resource: nil, rule: nil, phase: 'tool', agent: nil, at: nil)
      stamp = at.nil? ? Time.now : at
      decision = {}
      decision['tool'] = tool.to_s
      decision['action'] = action.to_s
      decision['resource'] = truncate(resource)
      decision['rule'] = rule
      decision['decision'] = 'denied'
      decision['phase'] = phase.to_s
      decision['agent'] = agent
      decision['at'] = Runes::Compat.utc_iso8601(stamp)

      emit(decision)
      decision
    end

    def self.emit(decision)
      if capped?
        @suppressed = @suppressed.to_i + 1
        unless @warned
          @warned = true
          warn "[GuardTelemetry] more than #{MAX_PER_MINUTE} denials in a minute; " \
               'further denials are counted but not published'
        end
        return decision
      end

      current = @sink
      current&.call(decision)
      decision
    rescue StandardError => e
      warn "[GuardTelemetry] sink failed: #{e.class}: #{e.message}"
      decision
    end

    def self.capped?
      now = Runes::Compat.monotonic
      @window_started ||= now
      if now - @window_started >= 60
        @window_started = now
        @window_count = 0
        @warned = false
      end
      @window_count = @window_count.to_i + 1
      @window_count > MAX_PER_MINUTE
    end

    def self.truncate(resource)
      text = resource.to_s
      return text if text.bytesize <= MAX_RESOURCE_BYTES

      "#{text.byteslice(0, MAX_RESOURCE_BYTES).to_s.scrub}…"
    end
  end
end
