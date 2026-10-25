# The DECLARED fleet, as opposed to the OBSERVED one (FleetTopology).
#
# A `.fleet.rb` file is static analysis material (docs/FLEET_DSL.md §8):
# loading it through the harness's own loader yields the declared roles,
# routes, channels and rules plus the determinism fingerprint — the same
# extracts the conformance suite golden-tests — without starting anything.
# The topology page reconciles that declaration against the graph derived
# from packets: a role nobody has observed yet is *silent*, traffic between
# two agents with no declared route edge is *undeclared*, and the fingerprint
# says exactly which file the drift is relative to.
#
# The observatory stays read-only here: it consumes the static extracts, it
# never runs a fleet or subscribes to anything.
#
# Path resolution mirrors JournalTail: `RUNES_OBSERVER_FLEET` names a file
# explicitly (an operator who names a file means it — a bad file renders its
# error on the page instead of silently disappearing), `off` disables the
# feature, and without either the sibling harness checkout's example fleet
# is used when present. A missing harness means no example, so no panel.
class FleetDeclaration
  Role     = Struct.new(:id, :model, :tools, keyword_init: true)
  Channel  = Struct.new(:id, :topic, :schema, :retain, keyword_init: true)
  Edge     = Struct.new(:from, :to, keyword_init: true)
  Rule     = Struct.new(:id, :source, :line, keyword_init: true)
  Overview = Struct.new(:path, :name, :fingerprint, :transport, :group, :runtime_user,
                        :roles, :channels, :edges, :rules, keyword_init: true)

  # The difference between what the file declares and what the fabric has
  # shown. `*_silent` buckets are declared-but-never-observed; `*_undeclared`
  # buckets are observed-but-never-declared. Both directions matter: a silent
  # role may be a fleet that never started, an undeclared agent may be a
  # typo — or a stranger.
  Drift = Struct.new(:roles_silent, :agents_undeclared, :edges_silent, :edges_undeclared,
                     keyword_init: true) do
    def quiet? = roles_silent.empty? && agents_undeclared.empty? &&
                 edges_silent.empty? && edges_undeclared.empty?
  end

  class << self
    # nil = feature off; otherwise the fleet file in effect.
    def path
      explicit = ENV.fetch("RUNES_OBSERVER_FLEET", "").strip
      return nil if explicit.casecmp("off").zero?
      return explicit unless explicit.empty?

      example = File.expand_path("../../../examples/prospection.fleet.rb", __dir__)
      File.exist?(example) ? example : nil
    end

    # nil when off or the file failed to load; the presentation struct when
    # a declaration is in effect. Failures go to `error`, never to a raise —
    # a fleet file being edited must not 500 the page.
    def overview
      state = load_state
      return nil unless state&.dig(:world)

      world = state[:world]
      Overview.new(
        path: state[:path],
        name: world.name,
        fingerprint: world.fingerprint,
        transport: world.transport.to_s,
        group: world.group.to_s,
        runtime_user: world.runtime_user,
        roles: world.roles.map { |id, role|
          Role.new(id: id.to_s, model: role.model.to_s,
                   tools: role.tools.empty? ? "none" : role.tools.keys.map(&:to_s).join(", "))
        },
        channels: world.channels.map { |id, ch|
          Channel.new(id: id.to_s, topic: ch.topic, schema: ch.schema&.to_s, retain: ch.retain)
        },
        edges: world.edges.select { |e| world.role?(e.from) && world.role?(e.to) }
                          .map { |e| Edge.new(from: e.from.to_s, to: e.to.to_s) }.uniq,
        rules: world.rules.map { |r| Rule.new(id: r.id, source: "#{r.source_kind}:#{r.source}", line: r.line) }
      )
    end

    # nil when off or loaded; the failure message when the file is present
    # but unreadable (parse error, validation refusal, missing harness).
    def error
      state = load_state
      state && state[:error]
    end

    # nil when the feature is off; otherwise the four drift buckets between
    # the declaration and the observed graph FleetTopology built.
    def drift(nodes, edges)
      state = load_state
      world = state && state[:world]
      return nil unless world

      observed_ids = nodes.map(&:agent_id)
      declared_ids = world.roles.keys.map(&:to_s)
      declared_pairs = world.edges.select { |e| world.role?(e.from) && world.role?(e.to) }
                            .map { |e| [e.from.to_s, e.to.to_s] }.uniq
      observed_pairs = edges.map { |e| [e.from, e.to] }.uniq
      Drift.new(
        roles_silent: declared_ids - observed_ids,
        agents_undeclared: observed_ids - declared_ids,
        edges_silent: declared_pairs - observed_pairs,
        edges_undeclared: observed_pairs - declared_pairs
      )
    end

    # Tests mutate ENV and files; the cache is keyed on both.
    def reset_cache!
      @state = nil
    end

    private

    # Single-entry cache keyed on [path, mtime]: editing the fleet file is
    # visible on the next request without an app restart, and a failure is
    # memoized too (retry only when the file changes again).
    def load_state
      p = path
      return nil if p.nil?

      stamp = begin
                [p, File.mtime(p)]
              rescue SystemCallError
                [p, :missing]
              end
      return @state if @state && @state[:stamp] == stamp

      @state = build_state(p, stamp)
    end

    def build_state(p, stamp)
      require "runes/fleet"
      { stamp: stamp, path: p, world: Runes::Fleet.load_file(p), error: nil }
    rescue ::LoadError, SystemCallError, Runes::Fleet::LoadError => e
      { stamp: stamp, path: p, world: nil, error: "#{e.class}: #{e.message}" }
    end
  end
end
