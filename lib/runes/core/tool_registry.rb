require 'json'
require 'digest'

module Runes
  module Core
    # Loads per-tool manifests from `tools/<name>/capabilities.json`,
    # merges them into the Guard's policy, and returns a registry of
    # AgentCard-shaped metadata that can be published onto the bus via
    # retained messages.
    #
    # Expected on-disk layout:
    #
    #   tools/
    #     hello/
    #       capabilities.json    → capability policy
    #       card.json            → A2A-style agent card (optional)
    #       run.rb               → implementation (optional)
    #
    # Tool manifests let the harness grow without editing source code:
    # adding a new tool becomes "drop a directory in tools/ and restart".
    class ToolRegistry
      DEFAULT_TOOLS_DIR = File.expand_path('../../../tools', __dir__)

      # Manifest parse limits (S-R3): a hostile/huge card.json must not be
      # a boot-time memory/CPU DoS.
      MAX_MANIFEST_BYTES = 256 * 1024
      MAX_MANIFEST_NESTING = 32

      # Tool names become MQTT topic fragments — constrain them to a safe
      # charset up front (enhancement) so a weird directory name can never
      # smuggle wildcards or separators into topics.
      TOOL_NAME_RE = /\A[A-Za-z0-9_-]{1,64}\z/.freeze

      attr_reader :tools_dir, :cards, :policy_fragment, :manifest_digests

      def initialize(tools_dir: DEFAULT_TOOLS_DIR)
        @tools_dir = tools_dir
        rescan
      end

      def empty?
        @cards.empty?
      end

      # Rebuild @cards/@policy_fragment from disk — enables hot tool
      # loading without a dispatcher restart (enhancement).
      def rescan
        cards = {}
        fragment = { 'tools' => {} }
        digests = {}
        scan_into(cards, fragment, digests)
        drift = @manifest_digests
        @cards = cards
        @policy_fragment = fragment
        @manifest_digests = digests
        log_policy_drift(drift, digests)
        self
      end

      private

      def scan_into(cards, fragment, digests)
        return unless Dir.exist?(@tools_dir)

        tools_root = File.realpath(@tools_dir)
        Dir.glob(File.join(@tools_dir, '*')).sort.each do |entry|
          # TOCTOU-safe: check-then-use races on removed entries crash
          # the scan (R2), so every per-entry step rescues SystemCallError.
          begin
            next unless File.directory?(entry)
            name = File.basename(entry)
            next unless name.match?(TOOL_NAME_RE)

            # Symlinked tool dirs would load manifests (and run.rb) from
            # outside the project tree (S-R4) — require a real directory.
            real = File.realpath(entry)
            next unless real.start_with?(tools_root + File::SEPARATOR) || real == tools_root

            policy_path = File.join(entry, 'capabilities.json')
            digests[name] = file_digest(policy_path)

            card_path = File.join(entry, 'card.json')
            card = safe_load_json(card_path) || default_card(name)
            card['name'] = name
            card['path'] = entry
            cards[name] = card

            if (pol = safe_load_json(policy_path))
              # capabilities.json holds only this tool's rules (mqtt_publish,
              # mqtt_subscribe, ...). The fragment we hand to Guard is
              # already keyed by tool name. Registered manifest tools may
              # be executed by planner steps (S-W3): grant `execute` unless
              # the manifest defines its own rule.
              pol = { 'execute' => ['#'] }.merge(pol)
              fragment['tools'][name] = pol
            end
          rescue Errno::ENOENT, Errno::EACCES, Errno::ELOOP, SystemCallError
            next # entry vanished mid-scan or is unreadable — skip it
          end
        end
      end

      def file_digest(path)
        return nil unless File.file?(path)
        Digest::SHA256.hexdigest(File.read(path, MAX_MANIFEST_BYTES))
      rescue SystemCallError
        nil
      end

      # Manifest integrity: hash capabilities.json at boot and flag drift
      # vs the previous scan (enhancement / R5 — the `digest` require is
      # now load-bearing).
      def log_policy_drift(previous, current)
        return if previous.nil?

        changed = current.select { |name, d| previous[name] && previous[name] != d }
        removed = previous.keys - current.keys
        warn "[ToolRegistry] policy drift since last scan: changed=#{changed.keys.inspect} removed=#{removed.inspect}" if changed.any? || removed.any?
      end

      def safe_load_json(path)
        # No pre-check: File.file? + File.read is a check-then-use race
        # (R2). Read directly and rescue system errors.
        JSON.parse(File.read(path, MAX_MANIFEST_BYTES), max_nesting: MAX_MANIFEST_NESTING)
      rescue Errno::ENOENT
        nil # optional manifest — absent is fine
      rescue JSON::ParserError => e
        warn "[ToolRegistry] skipping malformed #{path}: #{e.message}"
        nil
      rescue ArgumentError => e
        warn "[ToolRegistry] skipping oversized/malformed #{path}: #{e.message}"
        nil
      end

      def default_card(name)
        {
          'name' => name,
          'description' => '(no card.json found)',
          'version' => '0.0.0',
          'capabilities' => []
        }
      end
    end
  end
end
