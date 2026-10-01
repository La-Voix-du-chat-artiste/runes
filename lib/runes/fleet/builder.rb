# frozen_string_literal: true

require_relative "load_error"
require_relative "world"
require_relative "rule"

module Runes
  module Fleet
    # The fixed bindings fleet files are evaluated in (spec §4: "evaluated
    # once at load time in a fixed binding — no self tricks"). The Walker
    # has already proven the file only uses whitelisted constructs; the
    # builders give those constructs their semantics and enforce
    # placement. Every violation raises LoadError (P3), so a failed load
    # leaves zero partial world (§10).
    #
    # Builders validate eagerly where the error is local (duplicate ids,
    # bad shapes) and defer to finalize! only for cross-references (route
    # endpoints), so declaration order stays free without giving up
    # fail-closed loading.
    class Builder
      SAFE_ID = /\A[A-Za-z0-9][A-Za-z0-9._-]*\z/.freeze
      SAFE_TOPIC = %r{\Arunes/[A-Za-z0-9][A-Za-z0-9/+._-]*\z}.freeze
      TRANSPORTS = %i[inproc mqtt311 mqtt5 auto].freeze
      RESERVED = {
        "spawn" => "process orchestration stays outside the DSL (spec §5.4)",
        "cell" => "mutable cells are v0.2 (spec §4.5/§14.3)",
        "interval" => "dynamic schedules stay in host code — use cron: (spec §4.6)"
      }.freeze

      def self.build(source, path:, args: {})
        top = TopBuilder.new(args)
        begin
          top.instance_eval(source, path.to_s, 1)
        rescue LoadError
          raise
        rescue NoMethodError => e
          # A call the Walker admitted (same whitelist) that this binding
          # does not implement: report it as a fleet error, not a Ruby
          # NoMethodError with an internal backtrace.
          raise LoadError, "fleet #{path}: unknown declaration `#{e.name}` (#{e.message})"
        rescue NameError => e
          raise LoadError, "fleet #{path}: #{e.message}"
        end
        top.finalize
      end

      # Only `fleet` exists at the top level (spec §4.1: exactly one fleet
      # block per file).
      class TopBuilder
        def initialize(args)
          @args = args.transform_keys(&:to_s)
          @world_builder = nil
        end

        def fleet(name, &block)
          raise LoadError, "fleet: exactly one fleet block per file (spec §4.1)" if @world_builder

          @world_builder = WorldBuilder.new(name, @args)
          @world_builder.instance_eval(&block) if block
        end

        def config(*)
          raise LoadError, "fleet: `config` belongs inside the fleet block (spec §7)"
        end

        def finalize
          raise LoadError, "fleet: missing the fleet block (spec §4.1)" unless @world_builder

          @world_builder.finalize
        end

        def method_missing(name, *, &)
          if RESERVED.key?(name.to_s)
            raise LoadError, "fleet: `#{name}` is reserved — #{RESERVED[name.to_s]}"
          end

          raise LoadError, "fleet: unknown top-level declaration `#{name}` (spec §4)"
        end

        def respond_to_missing?(*) = false
      end

      class WorldBuilder
        DEFAULT_CONFIG = { "env" => "development", "max_actions_per_event" => 16 }.freeze

        attr_reader :name

        def initialize(name, args)
          @name = validate_id(name, "fleet name").to_s
          @args = args
          @description = nil
          @transport = nil
          @group = nil
          @config_file = nil
          @roles = {}
          @channels = {}
          @raw_edges = []
          @facts = {}
          @schedules = {}
          @raw_rules = []
        end

        def description(text)
          @description = text.to_s
        end

        def transport(kind)
          kind = kind.to_sym
          unless TRANSPORTS.include?(kind)
            raise LoadError, "fleet: unknown transport #{kind.inspect} (expected one of #{TRANSPORTS.join(', ')})"
          end

          @transport = kind
        end

        def group(name)
          @group = validate_id(name, "group").to_s
        end

        def config(hash = nil, &)
          raise LoadError, "fleet: `config` takes one hash literal (spec §7)" unless hash.is_a?(Hash)
          raise LoadError, "fleet: duplicate config block (spec §7 precedence ladder)" if @config_file

          @config_file = hash
        end

        def agent(id, &block)
          id = validate_id(id, "agent id")
          raise LoadError, "fleet: duplicate agent #{id.inspect} (spec §4.2)" if @roles.key?(id)

          builder = RoleBuilder.new(id)
          builder.instance_eval(&block) if block
          @roles[id] = builder.finalize
        end

        def channel(id, topic, schema: nil, retain: false)
          id = validate_id(id, "channel id")
          topic = topic.to_s
          unless topic.match?(SAFE_TOPIC)
            raise LoadError, "fleet: channel topic #{topic.inspect} must match #{SAFE_TOPIC.source} (fail closed)"
          end
          raise LoadError, "fleet: duplicate channel #{id.inspect}" if @channels.key?(id)
          if @channels.values.any? { |ch| ch.topic == topic }
            raise LoadError, "fleet: topic #{topic.inspect} is already bound to another channel"
          end

          @channels[id] = World::Channel.new(id: id, topic: topic, schema: schema&.to_sym, retain: retain == true)
        end

        # Routes are directed edges (spec §4.4). Two spellings, one shape:
        #   route :scraper, :writer, :reviewer   # a path, each consecutive pair an edge
        #   route :reviewer, :outbox, when: :accepted
        #   route scraper: :writer               # keyword form, one edge per pair
        # Endpoints may be agent roles or channels; which is validated at
        # finalize!, so declaration order stays free.
        def route(*roles, **kw)
          when_guard = kw.key?(:when) ? kw.delete(:when) : nil
          chain = roles
          chain += kw.to_a.flatten(1) if kw.any? # keyword spelling: one edge per pair
          if chain.length < 2
            raise LoadError, "fleet: route needs at least two endpoints (spec §4.4)"
          end

          chain.each_cons(2) do |from, to|
            @raw_edges << [from.to_sym, to.to_sym, when_guard]
          end
        end

        def fact(id, value)
          id = validate_id(id, "fact id")
          raise LoadError, "fleet: duplicate fact #{id.inspect} (spec §4.5)" if @facts.key?(id)

          @facts[id] = World::Fact.new(id: id, value: value)
        end

        def schedule(id, cron: nil, interval: nil)
          raise LoadError, "fleet: `interval` schedules are reserved for host code — use cron: (spec §4.6)" if interval

          id = validate_id(id, "schedule id")
          raise LoadError, "fleet: duplicate schedule #{id.inspect}" if @schedules.key?(id)
          unless cron.is_a?(String) && cron.split(/\s+/).length == 5
            raise LoadError, "fleet: schedule #{id.inspect} needs a 5-field cron string (got #{cron.inspect})"
          end

          @schedules[id] = World::Schedule.new(id: id, cron: cron)
        end

        # Rules (spec §5): `on :source, guard: ->(e) { ... } do |e| ...
        # end`. Both spellings are sugar over the same triple; the block
        # binds exactly |e| and its ONLY effects are the task/publish/
        # notify actions (§5.4). Actions are captured at run time; the
        # finalize pass dry-runs the block once to validate whatever is
        # statically reachable, and the engine re-validates every action
        # at run time (fail closed, §10).
        def on(source, guard: nil, &block)
          raise LoadError, "fleet: `on` needs a block (spec §5.1)" unless block

          params = block.parameters
          unless params.length == 1 && %i[req opt].include?(params.first[0])
            raise LoadError, "fleet: `on` blocks must take exactly |e| (spec §5.1)"
          end
          if guard && !(guard.respond_to?(:call) && guard_lambda_arity(guard) == 1)
            raise LoadError, "fleet: `guard:` must be a ->(e) { ... } lambda (spec §5.1)"
          end

          @raw_rules << [source.to_sym, guard, block]
        end

        def finalize
          raise LoadError, "fleet: transport is required (one of #{TRANSPORTS.join(', ')})" unless @transport

          edges = @raw_edges.map do |from, to, when_guard|
            unless @roles.key?(from) || @channels.key?(from)
              raise LoadError, "fleet: route source #{from.inspect} is not a declared agent or channel (spec §4.4)"
            end
            unless @roles.key?(to) || @channels.key?(to)
              raise LoadError, "fleet: route target #{to.inspect} is not a declared agent or channel (spec §4.4)"
            end

            World::Edge.new(from: from, to: to, when: when_guard)
          end

          world = World.new(
            name: @name, description: @description, transport: @transport,
            group: @group, config: DEFAULT_CONFIG.merge(stringify(@config_file || {})).merge(@args)
          )
          @roles.each { |id, role| world.roles[id] = role }
          @channels.each { |id, ch| world.channels[id] = ch }
          edges.each { |e| world.edges << e }
          @facts.each { |id, f| world.facts[id] = f }
          @schedules.each { |id, s| world.schedules[id] = s }
          @raw_rules.each_with_index do |(source, guard, block), index|
            kind, name = Rule.classify(source, world)
            rule = Rule.new(
              id: "#{name}-#{index}", source_kind: kind, source: name,
              guard: guard, block: block, line: block.source_location&.last
            )
            validate_rule_actions!(rule, world, edges)
            world.rules << rule
          end
          world
        end

        def method_missing(name, *, &)
          if RESERVED.key?(name.to_s)
            raise LoadError, "fleet: `#{name}` is reserved — #{RESERVED[name.to_s]}"
          end

          raise LoadError, "fleet: unknown declaration `#{name}` inside fleet block (spec §4)"
        end

        def respond_to_missing?(*) = false

        private

        def guard_lambda_arity(guard)
          params = guard.parameters
          return nil unless params.length == 1 && %i[req opt].include?(params.first[0])

          1
        end

        # Static validation of the actions the dry-run reaches (§4.4(b)/
        # §5.4): task targets must be declared roles reachable on a route
        # edge, publish targets must be declared channels, notify levels
        # are pinned. Branches the probe event does not take are re-checked
        # by the engine at run time — nothing undeclared ever executes.
        def validate_rule_actions!(rule, world, edges)
          captured = RuleContext.new(world, probe_event)
          catch(:rule_next) { captured.instance_exec(probe_event, &rule.block) }
        rescue StandardError
          nil # guards/conditions over the probe event raise; what was
          # captured before the raise is still validated below
        ensure
          validate_actions!(rule, world, edges, captured&.actions || [])
        end

        def probe_event
          # Every field reads as its own name: any `e.foo` in a condition
          # is truthy, so unconditioned actions run and get validated.
          @probe_event ||= Event.new(
            id: "probe", at: Time.at(0).utc, kind: :probe, source: :probe,
            fields: Hash.new { |_h, k| k.to_s }
          )
        end

        def validate_actions!(rule, world, edges, actions)
          actions.each do |action|
            case action[:kind]
            when :task
              target = action[:target]
              unless world.role?(target) && edges.any? { |e| world.role?(e.to) && e.to == target }
                raise LoadError,
                      "fleet: rule #{rule.id} tasks #{target.inspect}, which is not on a declared route edge (§5.4)"
              end
            when :publish
              unless world.channel?(action[:channel])
                raise LoadError, "fleet: rule #{rule.id} publishes to undeclared channel #{action[:channel].inspect} (§5.4)"
              end
            when :notify
              unless RuleContext::NOTIFY_LEVELS.include?(action[:level])
                raise LoadError,
                      "fleet: rule #{rule.id} notify level #{action[:level].inspect} (expected info/warn/error)"
              end
            end
          end
        end

        def stringify(hash)
          hash.map { |k, v| [k.to_s, v] }.to_h
        end

        def validate_id(value, what)
          s = value.to_s
          unless s.match?(SAFE_ID)
            raise LoadError, "fleet: invalid #{what} #{s.inspect} (expected #{SAFE_ID.source})"
          end

          s.to_sym
        end
      end

      # Agent-role declarations (spec §4.2). `tools` is default-deny AND
      # loud: an agent without a tools clause is a load error, never an
      # implicit empty set — the explicit form of "nothing" is `tools :none`.
      class RoleBuilder
        def initialize(id)
          @id = id
          @model = nil
          @model_opts = {}
          @tools = nil
          @workspace = nil
          @identity = nil
          @concurrency = nil
        end

        def model(name, **opts)
          @model = name.to_s
          @model_opts = opts
        end

        def tools(grants)
          @tools = case grants
                   when :none then {}
                   when Hash
                     grants.each do |tool, grant|
                       case grant
                       when :allow then nil
                       when Hash
                         unless grant.keys == [:allow] &&
                                (grant[:allow] == :all || grant[:allow].is_a?(Array))
                           raise LoadError,
                                 "fleet: agent #{@id.inspect} tool #{tool.inspect} grant must be " \
                                 "{ allow: [...] } or { allow: :all } (got #{grant.inspect})"
                         end
                       else
                         raise LoadError,
                               "fleet: agent #{@id.inspect} tool #{tool.inspect} grant must be " \
                               ":allow or a hash (got #{grant.inspect})"
                       end
                     end
                     grants
                   else
                     raise LoadError,
                           "fleet: agent #{@id.inspect} tools must be a hash or :none (got #{grants.inspect})"
                   end
        end

        def workspace(path)
          @workspace = path.to_s
        end

        def identity(path)
          @identity = path.to_s
        end

        def concurrency(n)
          unless n.is_a?(Integer) && n.positive?
            raise LoadError, "fleet: agent #{@id.inspect} concurrency must be a positive integer (got #{n.inspect})"
          end

          @concurrency = n
        end

        def finalize
          if @tools.nil?
            raise LoadError,
                  "fleet: agent #{@id.inspect} declares no tools clause — default-deny is loud, " \
                  "write `tools :none` for a read-only role (spec §4.2)"
          end

          World::Role.new(
            id: @id, model: @model, model_opts: @model_opts, tools: @tools,
            workspace: @workspace, identity: @identity, concurrency: @concurrency
          )
        end

        def method_missing(name, *, &)
          if RESERVED.key?(name.to_s)
            raise LoadError, "fleet: `#{name}` is reserved — #{RESERVED[name.to_s]}"
          end

          raise LoadError, "fleet: unknown declaration `#{name}` inside agent #{@id.inspect} (spec §4.2)"
        end

        def respond_to_missing?(*) = false
      end
    end
  end
end
