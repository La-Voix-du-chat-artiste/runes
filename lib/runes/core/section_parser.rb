# frozen_string_literal: true

require_relative '../json_facade'

module Runes
  module Core
    # Tolerant parser for the small section protocol used by cumulative
    # agents. It is not a Markdown parser: it recognizes a handful of heading
    # spellings, never splits inside fenced code, and falls back to the whole
    # text when a model ignores the protocol.
    class SectionParser
      MAX_INPUT_BYTES = 1_048_576

      HEADING = /\A\s*(?:#{'#'}{1,6}\s+(.+?)\s*:?|\*\*(.+?)\*\*\s*:?|<([A-Z][A-Z0-9 _-]{1,40})>\s*:?|([A-Z][A-Z0-9 _-]{1,40})\s*:?)\s*\z/
      # A bare ALL-CAPS line is only a heading when it names a protocol
      # section — models echo `IDENTITY` without `###`, but a plain reply
      # like `OK` must stay body text, not become an empty section.
      KNOWN_SECTIONS = %w[
        IDENTITY CAPACITIES CAPACITY DECISION BODY
        ANSWER REPONSE_CANDIDATE CITATIONS
        CRITIQUE CLAIMS UNSUPPORTED VERDICT VIOLATIONS ISSUES FINDINGS
      ].freeze
      FENCE = /\A\s*(```|~~~)/
      THINK = /<think(?:ing)?>.*?<\/think(?:ing)?>/mi
      CITATIONS = /Citations?\s*:\s*(.+?)\s*$/i

      def parse(raw)
        text = raw.to_s
        if text.bytesize > MAX_INPUT_BYTES
          return {
            sections: {},
            body: '',
            answer: '',
            citations: [],
            had_sections: false,
            raw: text,
            error: :too_large
          }
        end

        original = text.dup
        cleaned = text.gsub(THINK, '')
        sections = {}
        current = nil
        body_lines = []
        in_fence = false

        cleaned.each_line do |line|
          stripped = line.strip
          if stripped.match?(FENCE)
            in_fence = !in_fence
            append_line(sections, current, line)
            body_lines << line
            next
          end

          name = in_fence ? nil : heading_name(stripped)
          if name
            current = name
            sections[current] ||= +''
            next
          end

          append_line(sections, current, line)
          body_lines << line
        end

        sections.each_key { |key| sections[key] = sections[key].strip }
        body = body_lines.join.strip
        answer = sections['ANSWER'] || sections['REPONSE_CANDIDATE'] || body
        {
          sections: sections,
          body: body,
          answer: answer,
          citations: citations_from(cleaned, sections),
          had_sections: !sections.empty?,
          raw: original,
          error: nil
        }
      end

      private

      def heading_name(line)
        match = line.match(HEADING)
        return nil if match.nil?

        raw_name = match[1] || match[2] || match[3] || match[4]
        return nil if raw_name.nil?

        name = normalize(raw_name)
        # The bare ALL-CAPS alternative (match[4]) is restricted to known
        # protocol sections; the marked forms (#, **, <>, :) stay generic.
        return nil if match[4] && !KNOWN_SECTIONS.include?(name.to_s)

        name
      end

      def normalize(name)
        text = name.to_s.upcase.gsub(/[^A-Z0-9_]+/, '_').sub(/\A_+/, '').sub(/_+\z/, '')
        text.empty? ? nil : text
      end

      def append_line(sections, current, line)
        return if current.nil?

        sections[current] << line
      end

      def citations_from(text, sections)
        value = sections['CITATIONS'].to_s.strip
        if value.empty?
          line = text.each_line.find { |candidate| candidate.match?(CITATIONS) }
          return [] if line.nil?

          value = line.match(CITATIONS)[1].strip
        end
        return [] if value.empty? || value.match?(/\A(?:aucune|none|n\/a)\z/i)

        # The citation format itself uses `/` (book / chapter / code), so the
        # separator is `;`, `,` or a newline only. Splitting on `/` would shred
        # every valid citation into three unknown tokens.
        value.split(/[;,\n]/).map(&:strip).reject(&:empty?)
      end
    end
  end
end
