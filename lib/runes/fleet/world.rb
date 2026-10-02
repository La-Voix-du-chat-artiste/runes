# frozen_string_literal: true

require_relative "../sha256_facade"
require_relative "../json_facade"

module Runes
  module Fleet
    # The loaded world (spec §3): the static topology a fleet file
    # declares. Value objects only — no transport handles, no
    # subscriptions. Rules land on top of this in the rules phase.
    class World
      # A declared station in the topology (spec §3 "agent role"). Distinct
      # from a running process: one role may be served by N daemon
      # processes or share one. `tools` is always a normalized Hash —
      # `:none` and the absent-but-declared forms both end up explicit;
      # the ABSENT tools clause is a load error (default-deny is loud, §4.2).
      Role = Struct.new(:id, :model, :model_opts, :tools, :workspace, :identity, :concurrency, keyword_init: true)
      Channel = Struct.new(:id, :topic, :schema, :retain, keyword_init: true)
      # One directed edge. `when` is the raw guard expression (rules phase
      # compiles it); nil = unconditional.
      Edge = Struct.new(:from, :to, :when, keyword_init: true)
      Fact = Struct.new(:id, :value, keyword_init: true)
      Schedule = Struct.new(:id, :cron, keyword_init: true)
      # A declared payload contract (spec §4.3). The spec is a literal
      # hash — data, not code: "fields" maps field names to one of
      # string/number/integer/boolean/array/object, "required" lists the
      # fields that must be present. Deliberately tiny: it is a
      # fail-closed gate, not a JSON-Schema engine.
      class Schema < Struct.new(:id, :fields, :required, keyword_init: true)
        KINDS = %w[string number integer boolean array object].freeze

        # nil when the payload conforms; a short refusal reason otherwise
        # (§4.3: an invalid payload is refused like a guard denial — it
        # never reaches a rule guard).
        def validate(fields)
          missing = required.reject { |key| fields.key?(key) }
          return "missing required field(s) #{missing.join(", ")}" unless missing.empty?

          fields.each do |key, value|
            kind = self.fields[key.to_s]
            next if kind.nil? # undeclared fields pass: contracts narrow, never widen arbitrarily

            ok = case kind
                 when "string" then value.is_a?(String)
                 when "number" then value.is_a?(Numeric)
                 when "integer" then value.is_a?(Integer)
                 when "boolean" then value == true || value == false
                 when "array" then value.is_a?(Array)
                 when "object" then value.is_a?(Hash)
                 else true
                 end
            return "field #{key.inspect} is not a #{kind}" unless ok
          end
          nil
        end
      end

      attr_reader :name, :description, :transport, :group, :config,
                  :roles, :channels, :edges, :facts, :schedules, :rules,
                  :schemas, :rule_channels, :rule_task_targets

      def initialize(name:, description:, transport:, group:, config:)
        @name = name
        @description = description
        @transport = transport
        @group = group
        @config = config
        @roles = {}
        @channels = {}
        @edges = []
        @facts = {}
        @schedules = {}
        @rules = []
        @schemas = {}
        @rule_channels = []
        @rule_task_targets = []
      end

      def role?(id) = roles.key?(id)
      def channel?(id) = channels.key?(id)

      # ---- spec §8 static-analysis outputs ----

      # Merged view of every `tools` clause (§8.1) — the policy extract
      # that closes the "guard does not see runes" gap for the declarative
      # layer. `default_allow: false` is pinned, not configurable: a fleet
      # may only narrow, never widen.
      def policy_extract
        {
          "default_allow" => false,
          "roles" => roles.map { |id, role|
            [id.to_s, { "tools" => stringify_tools(role.tools) }]
          }.sort.to_h
        }
      end

      # ACL extract (§8.2): per-role topic pairs in the same shape
      # Runes::Security::ACL emits (access, topic). Only the fleet-derived
      # DELTA is produced here — an agent→agent route edge authorizes the
      # source to publish addressed tasks on the target's task topic and
      # the target to read them (§4.4: "an edge :a → :b authorizes :a to
      # publish on :b's task topic and nothing more"); an agent→channel
      # edge authorizes publishing on that channel's topic. Edges that
      # start at a channel authorize the fleet RUNTIME (it publishes on
      # the fabric under its host agent's ACL), so they appear in the
      # topology but not as role grants here. The base card/status/prompts
      # grants stay bin/runes-acl's job; the merge is the round-trip in
      # the conformance suite.
      def acl_extract
        grants = Hash.new { |h, k| h[k] = [] }
        edges.each do |edge|
          if role?(edge.to)
            grants[edge.from] << ["write", "runes/agents/#{edge.to}/tasks"] if role?(edge.from)
            grants[edge.to] << ["read", "runes/agents/#{edge.to}/tasks"]
          elsif channel?(edge.to) && role?(edge.from)
            grants[edge.from] << ["write", channels[edge.to].topic]
          end
        end
        grants.map { |role, pairs|
          [role.to_s, pairs.uniq.sort]
        }.sort.to_h
      end

      # Topology graph (§8.3), the shape the observatory's /topology
      # renders. Rules list in declaration order — the evaluation order
      # guarantee of §5.3.1 is part of the observable topology.
      def topology
        {
          "name" => name,
          "agents" => roles.keys.map(&:to_s),
          "edges" => edges.map { |e|
            { "from" => e.from.to_s, "to" => e.to.to_s, "when" => e.when&.to_s }
          },
          "channels" => channels.map { |id, ch| [id.to_s, ch.topic] }.sort.to_h,
          "rules" => rules.map(&:to_h)
        }
      end

      # Determinism certificate seed (§8.4): a stable fingerprint of the
      # whole analysed world. Same fleet file ⇒ same fingerprint, on any
      # machine — the conformance suite records it at boot.
      def fingerprint
        Runes::SHA256.hex(
          Runes::Json.generate([policy_extract, acl_extract, topology])
        )
      end

      # ---- the fleet runtime's own grants (spec §8.2) ----

      # The broker identity a fleet runs under: `fleet-<name>` (see
      # bin/runes-acl --fleet). The runtime publishes — never consumes —
      # so its grants are writes only, derived from what the loaded rules
      # can actually do (recorded by the loader's dry-run): the channels
      # rules publish to, the roles rules task, and the dead-letter
      # channel. Nothing else — the runtime can never widen the fleet.
      def runtime_user
        "fleet-#{name}"
      end

      def runtime_acl
        writes = rule_channels.map { |id| channels.fetch(id).topic }
        writes.concat(rule_task_targets.map { |id| "runes/agents/#{id}/tasks" })
        writes << channels[:dead_letter].topic if channels.key?(:dead_letter)
        writes.uniq.sort.map { |topic| ["write", topic] }
      end

      private

      def stringify_tools(tools)
        tools.map { |tool, grant|
          normalized = case grant
                       when :allow then "allow"
                       when Hash
                         allow = grant[:allow]
                         { "allow" => allow == :all ? "all" : Array(allow).map(&:to_s) }
                       else
                         grant.to_s
                       end
          [tool.to_s, normalized]
        }.sort.to_h
      end
    end
  end
end
