require_relative 'json_scan'
require_relative '../json_facade'

module Runes
  module Core
    # Parses an LLM planner response into a normalized list of steps.
    #
    # Two formats are supported:
    #   1. Preferred: JSON `{ "steps": [ { "tool": "...", "args": {...} }, ... ] }`
    #   2. Legacy text: `TOOL: x\nARGS: y\n---\nTOOL: ...`
    #
    # The result is always an Array of `{ tool:, args: }` Hashes.
    class PlanParser
      KNOWN_TOOLS = %w[write_file read_file run_command].freeze

      # Cap on untrusted planner output parsed as JSON (S-L3).
      MAX_PLAN_BYTES = 1024 * 1024
      MAX_JSON_NESTING = 32

      # @param raw [String] the LLM planner output
      # @return [Array<Hash{Symbol=>Object}>] list of steps
      def parse(raw)
        return [] if raw.nil?
        raw = raw.to_s
        return [] if raw.bytesize > MAX_PLAN_BYTES

        json_steps = try_parse_json(raw)
        return json_steps if json_steps

        try_parse_text(raw)
      end

      private

      def try_parse_json(raw)
        # Find the outermost JSON object even if the model wrapped it in
        # markdown fences or other prose. The scanner is STRING-AWARE
        # (L1/B4-4) and shared with the mission path via JsonScan (E4-4).
        doc = Runes::Core::JsonScan.extract_object(
          raw, max_bytes: MAX_PLAN_BYTES, max_nesting: MAX_JSON_NESTING
        )
        return nil if doc.nil?

        steps = doc['steps'] || doc['plan'] || doc['tool_calls']
        return nil unless steps.is_a?(Array)

        normalized = steps.filter_map do |s|
          next unless s.is_a?(Hash)
          tool = (s['tool'] || s['name']).to_s.strip
          next if tool.empty?
          warn_if_unknown_tool(tool)
          args = s['args'] || s['arguments'] || {}
          if args.is_a?(String)
            # String-encoded args that fail to parse must not silently
            # become {} (L2) — keep the raw payload so the failure is
            # visible downstream instead of producing a plausible-looking
            # empty-args step.
            parsed = safe_parse(args)
            if parsed.nil? && !args.strip.empty?
              warn "plan step '#{tool}' has unparseable string args (#{args.bytesize}B) — keeping raw"
              args = { '_raw' => args }
            else
              args = parsed
            end
          end
          args = {} unless args.is_a?(Hash)
          { tool: tool, args: args }
        end
        normalized.empty? ? nil : normalized
      end

      # Kept for callers/tests that used the parser's scanner directly; the
      # implementation is shared with the mission path (E4-4) so the two
      # cannot drift apart again.
      def matching_brace(raw, start)
        Runes::Core::JsonScan.matching_brace(raw, start)
      end

      def try_parse_text(raw)
        steps = []
        raw.split(/^-{3,}\s*$/).each do |chunk|
          next if chunk.strip.empty?
          tool_match = chunk.match(/^\s*TOOL:\s*(.+?)\s*$/i)
          # Multi-line JSON ARGS blobs are common; the lazy one-line
          # regex used to truncate them (L6). Match to the end of the
          # chunk — chunks are `---`-separated and hold one TOOL/ARGS.
          args_match = chunk.match(/^\s*ARGS:\s*(.+)\z/im)
          next unless tool_match && args_match

          tool = tool_match[1].strip
          warn_if_unknown_tool(tool)
          args_str = args_match[1].strip

          args =
            if args_str.start_with?('{')
              begin
                Runes::Json.parse(args_str, max_nesting: MAX_JSON_NESTING)
              rescue Runes::Json::ParseError
                { '_raw' => args_str }
              end
            elsif tool == 'write_file' && args_str.include?('|')
              path, content = args_str.split('|', 2)
              { 'path' => path, 'content' => content }
            elsif tool == 'run_command'
              { 'cmd' => args_str }
            elsif tool == 'read_file'
              { 'path' => args_str }
            else
              { '_raw' => args_str }
            end

          steps << { tool: tool, args: args }
        end
        steps
      end

      # KNOWN_TOOLS was dead (enhancement): warn on unknown tool names so
      # a mistyped/made-up tool is visible before the dispatcher rejects it.
      def warn_if_unknown_tool(tool)
        return if KNOWN_TOOLS.include?(tool)

        warn "[PlanParser] unknown tool '#{tool}' in plan (known: #{KNOWN_TOOLS.join(', ')})"
      end

      def safe_parse(str)
        Runes::Json.parse(str, max_nesting: MAX_JSON_NESTING)
      rescue Runes::Json::ParseError, ArgumentError
        nil
      end
    end
  end
end
