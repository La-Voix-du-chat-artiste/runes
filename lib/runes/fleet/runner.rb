# frozen_string_literal: true

require "fileutils"
require_relative "engine"

module Runes
  module Fleet
    # The daemon-facing wrapper around the rule Engine (the Phase C
    # wiring): owns the timer thread that calls tick, a JSONL journal
    # file, and start/stop that pairs with the dispatcher's lifecycle.
    # Everything behavioural stays in the Engine — the Runner adds only
    # process concerns (a thread, a file, a clock cadence).
    #
    # The journal file is append-only JSON Lines, one entry per line, the
    # fleet_boot record first — so `tail -f` on it is a live view of what
    # the fleet is doing, and the fingerprint on the boot line ties every
    # line back to the exact fleet file that produced it (§8.4).
    class Runner
      attr_reader :engine, :world, :journal_path

      def initialize(world, transport:, journal_path: nil, tick_every: 1.0,
                     ledger: nil, notifier: nil, now: nil)
        @world = world
        @tick_every = tick_every
        @running = false
        @thread = nil
        @file = nil
        sink = journal_path ? jsonl_sink(journal_path) : nil
        @engine = Engine.new(
          world, transport: transport, ledger: ledger, notifier: notifier,
          now: now, journal_sink: sink
        )
      end

      def start
        return self if @running

        @running = true
        engine.start
        start_timer_thread if @tick_every.positive?
        self
      end

      def stop
        return self unless @running

        @running = false
        @thread&.join(2)
        @thread = nil
        engine.stop
        @file&.close
        @file = nil
        self
      end

      def running? = @running

      # Direct delegation for tests and one-off tools: the Runner is the
      # process wrapper, not a behaviour gate.
      def tick(at = nil) = at ? engine.tick(at) : engine.tick

      private

      # tick_every <= 0 hosts NO timer: the documented way to run an
      # event-serving runner that never fires schedules (a `sleep 0` here
      # would spin a core — schedules belong on a timer-hosting runner).
      def start_timer_thread
        @thread = Thread.new do
          while @running
            begin
              engine.tick
            rescue StandardError => e
              warn "[Fleet] tick failed: #{e.class}: #{e.message}"
            end
            sleep @tick_every
          end
        end
      end

      def jsonl_sink(path)
        @journal_path = path
        dir = File.dirname(path)
        FileUtils.mkdir_p(dir) unless Dir.exist?(dir)
        # Opened lazily: stop closes the file, so a restarted Runner must
        # journal again instead of writing to a closed handle (the engine's
        # commit rescues that as a warning and drops the sink — silent loss).
        lambda do |entries|
          @file ||= File.open(path, "a")
          entries.each { |entry| @file.puts(Runes::Json.generate(entry)) }
          @file.flush
        end
      end
    end
  end
end
