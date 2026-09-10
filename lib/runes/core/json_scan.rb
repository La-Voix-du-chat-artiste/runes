require 'json'

module Runes
  module Core
    # String-aware, bounded extraction of a JSON object from untrusted
    # model output.
    #
    # There used to be two copies of this logic: PlanParser's scanner
    # (fixed for strings in the third audit) and a private Dispatcher
    # copy that was still brace-blind, so a mission whose todo text
    # contained a single `{` or `}` was silently rejected (B4-4).
    # Everything now goes through this module (E4-4).
    module JsonScan
      MAX_BYTES   = 1024 * 1024
      MAX_NESTING = 32

      module_function

      # Returns the parsed Hash, or nil when no complete object is found,
      # the payload is oversized, or the text is not valid JSON.
      def extract_object(text, max_bytes: MAX_BYTES, max_nesting: MAX_NESTING)
        str = text.to_s
        return nil if str.bytesize > max_bytes

        # Fast path: the whole reply is the object.
        parsed = parse(str, max_nesting)
        return parsed if parsed.is_a?(Hash)

        start = str.index('{')
        return nil if start.nil?

        finish = matching_brace(str, start)
        return nil if finish.nil?

        parsed = parse(str[start..finish], max_nesting)
        parsed.is_a?(Hash) ? parsed : nil
      end

      # Index of the `}` closing the object opened at `start`, or nil.
      # Tracks string literals and escapes so braces inside string values
      # (CSS, templates, code snippets) are ignored.
      def matching_brace(str, start)
        return nil if start.nil? || start.negative? || start >= str.length

        depth = 0
        in_string = false
        escape = false
        str[start..].each_char.with_index(start) do |ch, i|
          if in_string
            if escape
              escape = false
            elsif ch == '\\'
              escape = true
            elsif ch == '"'
              in_string = false
            end
          else
            case ch
            when '"' then in_string = true
            when '{' then depth += 1
            when '}'
              depth -= 1
              return i if depth.zero?
            end
          end
        end
        nil
      end

      def parse(str, max_nesting)
        JSON.parse(str, max_nesting: max_nesting)
      rescue JSON::ParserError, ArgumentError
        nil
      end
    end
  end
end
