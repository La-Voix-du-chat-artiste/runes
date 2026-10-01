# frozen_string_literal: true

require_relative "load_error"

module Runes
  module Fleet
    # A loaded rule (spec §3/§5): the triple (source, guard, actions) as
    # data. `guard` and `block` are the file's own procs — safe to hold
    # and call because the Walker has already proven they use only the §6
    # subset, and the builders have validated their placement.
    class Rule
      SOURCES = {
        presence: %i[agent_online agent_offline],
        lifecycle: %i[mission_failed step_failed],
        guard_denied: %i[guard_denied]
      }.freeze

      attr_reader :id, :source_kind, :source, :guard, :block, :line

      def initialize(id:, source_kind:, source:, guard:, block:, line:)
        @id = id
        @source_kind = source_kind
        @source = source
        @guard = guard
        @block = block
        @line = line
      end

      # Classify a raw `on :name` source against the declared world.
      # Unknown names are load errors (§5.2) — channels and schedules are
      # checked by the caller against the world's own tables.
      def self.classify(source, world)
        sym = source.to_sym
        SOURCES.each do |kind, names|
          return [kind, sym] if names.include?(sym)
        end
        return [:channel, sym] if world.channel?(sym)
        return [:schedule, sym] if world.schedules.key?(sym)

        raise LoadError,
              "fleet: unknown event source #{source.inspect} (§5.2: declare the channel, " \
              "the schedule, or use agent_online/agent_offline/mission_failed/step_failed/guard_denied)"
      end

      def to_h
        { "id" => id, "source" => "#{source_kind}:#{source}", "line" => line }
      end
    end

    # An immutable observation from the fabric (§3), as guards see it:
    # `e.score`, `e[:score]`, with :now pinned to the RECEIPT time (§6 —
    # never wall clock inside guards; the engine stamps it).
    class Event
      attr_reader :id, :at, :kind, :source, :fields

      def initialize(id:, at:, kind:, source:, fields:)
        @id = id
        @at = at
        @kind = kind
        @source = source
        @fields = fields.transform_keys(&:to_s)
      end

      def [](key) = fields[key.to_s]

      # Unknown fields raise NoMethodError — and a guard that raises is a
      # refusal event, never a silent skip (§5.3.2).
      def method_missing(name, *, &)
        return fields[name.to_s] if fields.key?(name.to_s)

        super
      end

      def respond_to_missing?(name, include_private = false)
        fields.key?(name.to_s) || super
      end
    end

    # The binding rule bodies run in — at load time (dry-run capture for
    # static validation) and at run time (real execution). Provides the
    # §6 helpers (fact, :now via the event) and records the §5.4 actions.
    class RuleContext
      NOTIFY_LEVELS = %i[info warn error].freeze

      attr_reader :actions

      def initialize(world, event)
        @world = world
        @event = event
        @actions = []
      end

      # §5.1 sugar: stop THIS rule for THIS event; other rules still fire.
      def next!
        throw(:rule_next)
      end

      # §6: fleet facts are read-only inside rules.
      def fact(name)
        fact = @world.facts[name.to_sym]
        raise KeyError, "unknown fleet fact #{name.inspect}" unless fact

        fact.value
      end

      # §5.4 actions — recorded, validated, then executed by the engine.
      def task(target, prompt, **opts)
        @actions << { kind: :task, target: target.to_sym, prompt: prompt.to_s, opts: opts }
      end

      def publish(channel, payload)
        @actions << { kind: :publish, channel: channel.to_sym, payload: payload }
      end

      def notify(text, level: :info)
        @actions << { kind: :notify, text: text.to_s, level: level.to_sym }
      end
    end
  end
end
