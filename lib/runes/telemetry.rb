# frozen_string_literal: true

require "json"
require "securerandom"
require "time"

module Runes
  # Workflow telemetry: the seam that makes a run observable.
  #
  # A rune executes in-process and, until this existed, published nothing — so
  # a workflow was invisible to the observatory and to anything else watching
  # the fabric (doc5.md O1.1 / OBSERVATORY_ROADMAP O1.1). The engine now emits
  # a small event stream at run and step boundaries, and a *sink* decides what
  # to do with it:
  #
  #   Runes::Telemetry.sink = ->(event) { ... }
  #   Runes::Telemetry.sink = Runes::Telemetry::TransportSink.new(transport: t)
  #
  # Emitting is best-effort by design: a telemetry failure must never fail a
  # run, so every emit is rescued and swallowed (with a warning).
  module Telemetry
    # Long outputs are truncated so one step cannot flood the bus or the
    # observer's database. The marker says how much was dropped.
    MAX_FIELD_BYTES = 4096

    KINDS = %w[run_started step_started step_finished run_finished].freeze

    class << self
      # A callable, or nil for "no telemetry" (the default — a plain library
      # user pays nothing).
      attr_accessor :sink

      def enabled?
        !sink.nil?
      end

      # Build a sink from a spec string: "mqtt"/"auto"/"1" publish on the
      # fabric, "off"/nil disable. Used by bin/runes-workflow.
      def build_sink(spec, settings: nil, transport: nil)
        value = spec.to_s.strip.downcase
        return nil if value.empty? || %w[0 false no off none].include?(value)

        require_relative "transport" unless defined?(Runes::Transport)
        transport ||= Runes::Transport.build(kind: nil, settings: settings)
        transport.connect unless transport.connected?
        TransportSink.new(transport: transport)
      end

      # The event a viewer needs to lay out a timeline: a monotonic-free,
      # wall-clock timestamp plus how long the step took.
      def now
        Time.now.utc
      end

      # Close the current sink (if it can be closed) and forget it. Call this
      # before a process exits: a sink that is never closed can lose its last
      # events, and a `run_finished` that never arrives is a run that never ends
      # as far as the observatory is concerned.
      def close!
        current = sink
        self.sink = nil
        current.respond_to?(:close) ? current.close : nil
      end
    end

    # One workflow run's identity and its sink. Every rune in the run shares
    # one of these (nested scopes included), so all their events carry the
    # same run_id and can be stitched back together.
    class Context
      attr_reader :run_id, :workflow, :params, :started_at

      def initialize(workflow:, sink: Telemetry.sink, run_id: nil, params: nil)
        @workflow = workflow.to_s
        @sink = sink
        @run_id = (run_id || SecureRandom.hex(8)).to_s
        @params = params
        @started_at = Telemetry.now
        @step_mutex = Mutex.new
        @step_index = 0
      end

      def enabled?
        !@sink.nil?
      end

      # Monotonic step counter for the whole run, so a viewer can order steps
      # even when two of them finish out of order (async runes).
      def next_step_index
        @step_mutex.synchronize { @step_index += 1 }
      end

      def run_started!(total_steps: nil)
        emit("run_started", workflow: @workflow, params: @params, total_steps: total_steps)
      end

      def run_finished!(status:, duration_ms:, error: nil, steps: nil, cost_usd: nil)
        emit("run_finished", status: status, duration_ms: duration_ms, error: error, steps: steps,
                             cost_usd: cost_usd)
      end

      def step_started!(rune:, scope: nil, index: nil)
        emit("step_started", rune: rune.type, name: rune.name.to_s, anonymous: rune.anonymous?,
                             scope: scope, index: index || next_step_index,
                             async: rune.instance_variable_get(:@config)&.async? || false)
      end

      def step_finished!(rune:, scope: nil, index: nil, status: "ok", duration_ms: nil,
                         output: nil, error: nil, cost_usd: nil, tokens: nil)
        emit("step_finished", rune: rune.type, name: rune.name.to_s, scope: scope,
                              index: index, status: status, duration_ms: duration_ms,
                              output: truncate(output), error: truncate(error),
                              cost_usd: cost_usd, tokens: tokens)
      end

      # Every event carries the run identity, so a sink can route on it
      # without keeping state.
      # Every key is a String, so the payload is identical whether it is
      # consumed in-process (tests, an embedded sink) or as JSON on the wire.
      def event(kind, fields)
        base = { "run_id" => @run_id, "kind" => kind, "workflow" => @workflow,
                 "at" => Telemetry.now.iso8601(3) }
        base.merge(fields.compact.transform_keys(&:to_s))
      end

      private

      def emit(kind, **fields)
        return false unless @sink

        payload = event(kind, fields)
        @sink.call(payload)
        true
      rescue StandardError => e
        warn "[Telemetry] #{kind} emit failed: #{e.class}: #{e.message}"
        false
      end

      def truncate(value)
        return nil if value.nil?

        text = value.is_a?(String) ? value : value.inspect
        return text if text.bytesize <= MAX_FIELD_BYTES

        dropped = text.bytesize - MAX_FIELD_BYTES
        "#{text.byteslice(0, MAX_FIELD_BYTES)}… (+#{dropped} bytes dropped)"
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

        @transport.publish(topic(run_id, kind), JSON.generate(event), qos: 1)
        @mutex.synchronize { @published += 1 }
        true
      end

      def topic(run_id, kind)
        "#{@prefix}/#{run_id}/#{kind}"
      end

      # Flush and close the transport.
      #
      # `call` publishes at QoS 1 *without* waiting for the PUBACK (telemetry
      # must not slow a run down), so the last events of a run sit in the socket
      # when the process exits — a `run_finished` that never arrives leaves the
      # observatory showing a run that is still "running" for ever. Whoever owns
      # the sink's lifetime must close it; `Runes::Telemetry.close!` is the
      # convenience for that.
      def close
        @transport.disconnect
        @closed = true
      rescue StandardError
        # Closing telemetry must never raise into a caller that is finishing.
        false
      ensure
        @published ||= 0
      end

      def closed? = @closed == true
    end
  end
end
