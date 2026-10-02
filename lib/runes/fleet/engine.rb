# frozen_string_literal: true

require_relative "load_error"
require_relative "rule"
require_relative "world"
require_relative "../sha256_facade"
require_relative "../json_facade"
require_relative "../request_ledger"

module Runes
  module Fleet
    # The rule engine (spec §5 run-time semantics) — hermetic by
    # construction: it speaks to the world only through the transport
    # seam, the request ledger and a journal array, so tests drive it
    # with the in-process transport and synthetic events. The daemon
    # (a later phase) owns start/stop, the timer loop that calls tick,
    # and persisting the journal; no thread lives HERE, which keeps
    # dispatch deterministic and replayable (§5.3.5).
    #
    # Semantics implemented exactly:
    #   §5.3.1  rules fire in declaration order, all matches, actions in
    #           rule order;
    #   §5.3.2  a guard/block that raises is a `rule_guard_error` refusal
    #           event — never a silent skip;
    #   §5.3.3  every action carries a deterministic request_id
    #           (fleet, rule, event, ordinal) claimed in the RequestLedger:
    #           a redelivered event can never execute the same action
    #           twice;
    #   §5.3.4  more than max_actions_per_event actions fails the EVENT
    #           to the dead-letter channel;
    #   §10     SchemaError (unparseable payload) and GuardError
    #           (undeclared action target) refuse loudly and keep the
    #           fleet running.
    class Engine
      PRESENCE_TOPIC = "runes/agents/+/status"
      GUARD_DENIED_TOPIC = "runes/guard/denied"
      LIFECYCLE_TOPIC = "runes/prompts/+/progress"
      TASK_TOPIC = "runes/agents/%s/tasks"

      attr_reader :world, :journal

      def initialize(world, transport:, ledger: nil, now: nil, max_actions: nil,
                     schema_validator: nil, notifier: nil, journal_sink: nil)
        @world = world
        @transport = transport
        @ledger = ledger || Runes::RequestLedger.new
        @now = now || -> { Time.now.utc }
        @max = max_actions || Integer(world.config["max_actions_per_event"] || 16)
        @schema_validator = schema_validator
        @notifier = notifier
        @journal_sink = journal_sink
        @journal = []
        @journal_mutex = Mutex.new
        @subscriptions = []
        @presence_states = {}
        @started = false
      end

      def started? = @started

      # Subscribe every rule source to the transport seam — under the
      # fleet's shared group, so N runners serving one fleet split the
      # events instead of double-firing (one delivery per group, the
      # MQTT 5 shared-subscription semantics; the per-process ledger then
      # suffices for idempotency). Schedules are the exception: tick runs
      # on every runner, so schedule rules fire once PER RUNNER — with
      # multiple runners, host the timer on one of them (the Runner's
      # tick_every can be set to 0 on the others).
      #
      # Atomic with respect to the World: the World was fully validated
      # at load, so if start runs at all the subscriptions describe a
      # complete fleet. The boot record (§8.4) lands in the journal with
      # the world's determinism fingerprint, so a journal can always be
      # tied to the exact fleet that produced it.
      def start
        return if @started

        @started = true
        subscribe_channels
        subscribe(PRESENCE_TOPIC) if rules_for(:presence).any?
        subscribe(GUARD_DENIED_TOPIC) if rules_for(:guard_denied).any?
        subscribe(LIFECYCLE_TOPIC) if rules_for(:lifecycle).any?
        commit([{ "kind" => "fleet_boot", "fleet" => world.name,
                  "fingerprint" => world.fingerprint,
                  "at" => Runes::Compat.utc_iso8601(@now.call) }])
        self
      end

      def stop
        @subscriptions.each { |sub| @transport.unsubscribe(sub) rescue nil }
        @subscriptions.clear
        @started = false
        self
      end

      # Schedules are events like any other (§4.6): the daemon's timer
      # loop calls tick (tests call it directly); nothing here sleeps.
      def tick(at = @now.call)
        world.schedules.each_value do |schedule|
          next unless cron_due?(schedule.cron, at)

          dispatch(:schedule, schedule.id.to_sym, { "schedule" => schedule.id.to_s }, at: at)
        end
      end

      # Transport callback — one entry point for every subscribed topic.
      def receive(message)
        topic = message.topic.to_s
        payload = message.payload.to_s

        if (m = topic.match(%r{\Arunes/agents/([^/]+)/status\z}))
          state = payload.strip
          return unless %w[online offline].include?(state)

          # §5.2 says TRANSITION: a retained card replay (e.g. right after
          # this runner starts) is state, not news — it seeds the map but
          # never fires. Live messages fire only when the state actually
          # changes, so a fleet restart does not re-notify every agent.
          agent = m[1]
          previous = @presence_states[agent]
          @presence_states[agent] = state
          return if message.retain
          return if previous == state

          dispatch(:presence, state == "online" ? :agent_online : :agent_offline,
                   { "agent" => agent, "status" => state })
        elsif topic == GUARD_DENIED_TOPIC
          dispatch(:guard_denied, :guard_denied, parse_payload(payload, topic) || {})
        elsif (m = topic.match(%r{\Arunes/prompts/([^/]+)/progress\z}))
          fields = parse_payload(payload, topic)
          return unless fields

          event_name = fields["event"].to_s
          dispatch(:lifecycle, event_name.to_sym, fields) if %w[mission_failed step_failed].include?(event_name)
        else
          channel = world.channels.values.find { |ch| ch.topic == topic }
          return unless channel

          fields = parse_payload(payload, topic)
          return unless fields

          # §4.3 fail-closed: a payload that violates the channel's
          # declared schema is refused like a guard denial — it never
          # reaches a rule guard (parse_payload already dead-letters).
          if channel.schema && (schema = world.schemas[channel.schema])
            reason = schema.validate(fields)
            if reason
              schema_refusal(topic, "schema #{channel.schema}: #{reason}")
              return
            end
          end

          dispatch(:channel, channel.id, fields)
        end
      end

      # Fire every rule whose source matches (kind + name), in
      # declaration order. Returns the journal entries this dispatch
      # appended — the determinism certificate of §5.3.5 is that the
      # same event always produces the same entries.
      def dispatch(kind, source, fields, at: @now.call, raw_payload: nil)
        event = Event.new(
          id: event_id(kind, source, fields),
          at: at, kind: kind, source: source, fields: fields
        )
        entries = []
        count = 0

        matching_rules(kind, source).each do |rule|
          next unless guard_passes?(rule, event, entries)

          context = RuleContext.new(world, event)
          caught = catch(:rule_next) do
            begin
              context.instance_exec(event, &rule.block)
            rescue StandardError => e
              # §5.3.2 — a rule body that raises is a refusal event.
              record(entries, rule, event, "rule_guard_error", error: "#{e.class}: #{e.message}")
              next
            end
            nil
          end

          context.actions.each_with_index do |action, ordinal|
            count += 1
            if count > @max
              fanout_exceeded!(event, rule, count, entries)
              commit(entries)
              return entries
            end

            execute(rule, event, action, ordinal + 1, entries)
          end
        end

        commit(entries)
        entries
      end

      private

      # ---- subscriptions ----

      def subscribe_channels
        channels_with_rules = rules_for(:channel).map(&:source).uniq
        channels_with_rules.each do |id|
          subscribe(world.channels.fetch(id).topic)
        end
      end

      def subscribe(topic)
        @subscriptions << @transport.subscribe(topic, group: @world.group) { |message| receive(message) }
      end

      # ---- §5.3 evaluation ----

      def matching_rules(kind, source)
        world.rules.select { |rule| rule.source_kind == kind && rule.source == source }
      end

      def rules_for(kind)
        world.rules.select { |rule| rule.source_kind == kind }
      end

      def guard_passes?(rule, event, entries)
        return true unless rule.guard

        begin
          !!rule.guard.call(event)
        rescue StandardError => e
          # §5.3.2 — a guard that raises is a refusal event, not a skip
          # that happens to look like a quiet non-match.
          record(entries, rule, event, "rule_guard_error", error: "guard: #{e.class}: #{e.message}")
          false
        end
      end

      def execute(rule, event, action, ordinal, entries)
        unless action_allowed?(action)
          record(entries, rule, event, "guard_refused", action: action)
          return
        end

        request_id = Runes::SHA256.hex("#{world.name}:#{rule.id}:#{event.id}:#{ordinal}")[0, 16]
        return if @ledger.seen?(request_id)
        return unless @ledger.claim(request_id)

        outcome =
          case action[:kind]
          when :task then execute_task(action, request_id, event)
          when :publish then execute_publish(action, request_id, event)
          when :notify then execute_notify(rule, event, action)
          end
        @ledger.complete(request_id, outcome.to_s[0, Runes::RequestLedger::MAX_OUTCOME_BYTES])
        record(entries, rule, event, "action", request_id: request_id, action: action, outcome: outcome)
      rescue StandardError => e
        # §10 ActionError — the rule is marked failed; the fleet keeps running.
        @ledger.complete(request_id, "error") if request_id
        record(entries, rule, event, "action_failed",
               action: action, error: "#{e.class}: #{e.message}")
      end

      # Run-time fail-closed validation — the load-time dry-run proved the
      # statically reachable actions; anything a branch hid from it is
      # refused HERE, at the moment it would otherwise execute (§10
      # GuardError, guard.denied telemetry semantics).
      def action_allowed?(action)
        case action[:kind]
        when :task
          target = action[:target]
          world.role?(target) && world.edges.any? { |e| world.role?(e.to) && e.to == target }
        when :publish
          world.channel?(action[:channel])
        when :notify
          RuleContext::NOTIFY_LEVELS.include?(action[:level])
        else
          false
        end
      end

      # §5.4: task lowers to an addressed A2A-style envelope on the
      # target's task topic — the same shape peers already consume.
      def execute_task(action, request_id, event)
        prompt = render_templates(action[:prompt], event)
        envelope = {
          request_id: request_id,
          prompt: prompt,
          mode: "fleet",
          from_envelope: true
        }
        topic = TASK_TOPIC % action[:target]
        @transport.publish(topic, Runes::Json.generate(envelope))
        { "topic" => topic }
      end

      def execute_publish(action, request_id, event)
        channel = world.channels.fetch(action[:channel])
        payload = action[:payload].each_with_object({}) do |(k, v), hash|
          hash[k.to_s] = v == :now ? Runes::Compat.utc_iso8601(event.at) : v
        end
        @transport.publish(channel.topic, Runes::Json.generate(payload))
        { "topic" => channel.topic }
      end

      # notify lowers to the observatory/TUI event pipeline (§5.4): the
      # telemetry sink when one is installed, plus the caller-supplied
      # notifier hook (the TUI/observatory bridge in the daemon phase).
      # A broken sink must never break the fleet — same contract as
      # Telemetry::Context#emit.
      def execute_notify(rule, event, action)
        notice = {
          "kind" => "fleet_notify", "fleet" => world.name, "rule" => rule.id,
          "level" => action[:level].to_s, "text" => render_templates(action[:text], event),
          "at" => Runes::Compat.utc_iso8601(event.at)
        }
        begin
          Runes::Telemetry.sink&.call(notice)
        rescue StandardError
          nil
        end
        @notifier&.call(notice)
        { "level" => action[:level].to_s }
      end

      def fanout_exceeded!(event, rule, count, entries)
        record(entries, rule, event, "fanout_exceeded", count: count, max: @max)
        dead = world.channels[:dead_letter]
        return unless dead

        @transport.publish(dead.topic, Runes::Json.generate(
          { "event" => "fanout_exceeded", "fleet" => world.name,
            "source_event" => event.id, "count" => count, "max" => @max }
        ))
      end

      # ---- helpers ----

      def event_id(kind, source, fields)
        Runes::SHA256.hex("#{kind}:#{source}:#{Runes::Json.generate(fields)}")[0, 16]
      end

      # §10 SchemaError: an unparseable payload never fires a rule; it is
      # refused and, when the fleet declares one, dead-lettered.
      def parse_payload(payload, topic)
        parsed = Runes::Json.parse(payload)
        return parsed if parsed.is_a?(Hash)

        schema_refusal(topic, "payload is not a JSON object")
        nil
      rescue Runes::Json::ParseError => e
        schema_refusal(topic, e.message)
        nil
      end

      def schema_refusal(topic, reason)
        dead = world.channels[:dead_letter]
        return unless dead

        @transport.publish(dead.topic, Runes::Json.generate(
          { "event" => "schema_refused", "fleet" => world.name, "topic" => topic, "reason" => reason }
        ))
      end

      # §6 templates: "%{field}" interpolates validated event fields and
      # facts only; an unknown name raises (→ action_failed, fleet keeps
      # running).
      def render_templates(text, event)
        text.to_s.gsub(/%\{([^}]+)\}/) do
          name = Regexp.last_match(1)
          if event.fields.key?(name)
            event.fields[name].to_s
          elsif (fact = world.facts[name.to_sym])
            fact.value.to_s
          else
            raise KeyError, "unknown template field #{name.inspect}"
          end
        end
      end

      def record(entries, rule, event, kind, **fields)
        entries << { "kind" => kind, "rule" => rule.id, "event" => event.id }.merge(stringify(fields))
      end

      # Journal entries are appended under a mutex: dispatches arrive on
      # transport reader threads AND the timer thread that calls tick, so
      # the in-memory journal and its sink must commit atomically. A sink
      # that fails (full disk, closed file) is warned about and dropped —
      # journaling must never break the fleet.
      def commit(entries)
        @journal_mutex.synchronize do
          @journal.concat(entries)
          begin
            @journal_sink&.call(entries)
          rescue StandardError => e
            warn "[Fleet] journal sink failed: #{e.class}: #{e.message}"
            @journal_sink = nil
          end
        end
      end

      def stringify(hash)
        hash.map { |k, v| [k.to_s, v.is_a?(Hash) ? stringify(v) : v] }.to_h
      end

      # 5-field cron (minute hour dom mon dow) with "*", "*/n", exact
      # numbers and the usual three-letter month/day names ("0 9 * * MON"
      # is the spec's own example); dow accepts 0-7 with both 0 and 7 as
      # Sunday. The daemon is expected to tick once per minute; tests tick
      # explicitly.
      CRON_MONTHS = { "jan" => 1, "feb" => 2, "mar" => 3, "apr" => 4, "may" => 5, "jun" => 6,
                      "jul" => 7, "aug" => 8, "sep" => 9, "oct" => 10, "nov" => 11, "dec" => 12 }.freeze
      CRON_DAYS = { "sun" => 0, "mon" => 1, "tue" => 2, "wed" => 3, "thu" => 4, "fri" => 5, "sat" => 6 }.freeze

      def cron_due?(cron, at)
        min, hour, dom, mon, dow = cron.split(/\s+/)
        field_match?(min, at.min) &&
          field_match?(hour, at.hour) &&
          field_match?(dom, at.day) &&
          field_match?(mon, at.month, names: CRON_MONTHS) &&
          field_match_dow?(dow, at.wday)
      end

      def field_match?(spec, value, names: nil)
        return true if spec == "*"

        if (m = spec.match(%r{\A\*/([0-9]+)\z}))
          return false if m[1].to_i.zero?

          (value % m[1].to_i).zero?
        else
          spec.split(",").any? do |part|
            part = part.downcase
            part = names[part].to_s if names && names.key?(part)
            Integer(part, exception: false) == value
          end
        end
      end

      def field_match_dow?(spec, wday)
        field_match?(spec, wday, names: CRON_DAYS) || (wday.zero? && spec.split(",").include?("7"))
      end
    end
  end
end
