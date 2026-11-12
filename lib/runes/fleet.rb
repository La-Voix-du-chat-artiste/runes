# frozen_string_literal: true

require_relative "fleet/load_error"
require_relative "fleet/walker"
require_relative "fleet/builder"
require_relative "fleet/engine"
require_relative "fleet/runner"

module Runes
  # The Fleet DSL (docs/FLEET_DSL.md, spec v0.1): a declarative world +
  # rules layer in a restricted, statically analyzable Ruby subset. This
  # module is the loader's front door — Walker (constructs) then Builder
  # (semantics), fail-closed and atomic (§10): a file that fails analysis
  # leaves no partial world behind.
  module Fleet
    SPEC_VERSION = "0.1"
    HEADER_RE = /\A#\s*fleet-spec:\s*([0-9]+\.[0-9]+)\s*\z/

    module_function

    def load_file(path, args: {}, loading: [])
      load(File.read(path), path: path, args: args, loading: loading)
    end

    # Bake a fleet file into pure data for the compiled fleet runtime:
    # load it (fail-closed, as always), probe every rule's actions once
    # (the block is a proc and cannot cross the compile boundary), and
    # return the world's baked hash. Guards are dropped in the baked form.
    def bake_file(path, args: {})
      bake_file_from_source(File.read(path), path: path, args: args)
    end

    def bake_file_from_source(source, path:, args: {})
      world = load(source, path: path, args: args)
      world.rules.each do |rule|
        probe = RuleContext.new(world, probe_event_for(rule))
        catch(:rule_next) { probe.instance_exec(probe_event_for(rule), &rule.block) }
        rule.instance_variable_set(:@baked_actions, probe.actions)
      end
      world.to_baked_h
    end

    def probe_event_for(_rule)
      # Same synthesized-fields trick as the loader's dry-run probe (incl.
      # its plausible values for known fields like score), so guards and
      # templates resolve at bake time.
      values = { "email" => "ada@example.fr", "score" => 1.0 }
      fields = Hash.new { |_h, k| values.fetch(k.to_s, k.to_s) }
      def fields.key?(_key) = true
      Event.new(id: "bake-probe", at: Time.at(0).utc, kind: :probe, source: :probe,
                fields: fields)
    end

    # Load a fleet document from a string. `args` are the load-time
    # parameters of spec §7 (lowest precedence: defaults < config block <
    # args). `loading` is the import stack for cycle detection (§14.4):
    # a file that imports itself, directly or transitively, refuses to load.
    def load(source, path: "(fleet)", args: {}, loading: [])
      abs = File.expand_path(path.to_s)
      raise LoadError, "fleet #{path}: import cycle detected (#{abs} is already being loaded)" if loading.include?(abs)

      check_header!(source, path)
      result = Prism.parse(source)
      unless result.errors.empty?
        err = result.errors.first
        raise LoadError, "fleet #{path}: syntax error at line #{err.location.start_line}: #{err.message}"
      end
      Walker.new(path).verify!(result.value)
      Builder.build(source, path: path, args: args, loading: loading + [abs])
    end

    # The spec version is declared in a leading comment (§13) so it is
    # visible to grep and to the L3 conformance gate without evaluating
    # anything.
    def check_header!(source, path)
      version = nil
      source.each_line do |line|
        text = line.strip
        next if text.empty?

        if (m = text.match(HEADER_RE))
          version = m[1]
          break
        end
        break unless text.start_with?("#")
      end
      if version.nil?
        raise LoadError,
              "fleet #{path}: missing `# fleet-spec: #{SPEC_VERSION}` header comment (spec §13)"
      end
      unless version == SPEC_VERSION
        raise LoadError,
              "fleet #{path}: unsupported fleet-spec #{version} (this loader speaks #{SPEC_VERSION})"
      end
    end
  end
end
