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

    def load_file(path, args: {})
      load(File.read(path), path: path, args: args)
    end

    # Load a fleet document from a string. `args` are the load-time
    # parameters of spec §7 (lowest precedence: defaults < config block <
    # args).
    def load(source, path: "(fleet)", args: {})
      check_header!(source, path)
      result = Prism.parse(source)
      unless result.errors.empty?
        err = result.errors.first
        raise LoadError, "fleet #{path}: syntax error at line #{err.location.start_line}: #{err.message}"
      end
      Walker.new(path).verify!(result.value)
      Builder.build(source, path: path, args: args)
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
