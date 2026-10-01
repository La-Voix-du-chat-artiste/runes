# frozen_string_literal: true

require_relative "util"
require_relative "errors"
require_relative "../json_facade"

module Runes
  class Rune
    # ------------------------------------------------------------------
    # Params: evaluation-time arguments passed to a rune's DSL method.
    # Plain runes only accept a positional (optional) name; system runes
    # (call/map/repeat) add `run:`. `new_from_params` turns these into an
    # instance.
    # ------------------------------------------------------------------
    class Params
      attr_reader :name

      def initialize(name = nil)
        @anonymous = name.nil?
        @name = name || Runes::Rune.generate_fallback_name
      end

      def anonymous?
        @anonymous
      end
    end

    # ------------------------------------------------------------------
    # Config: the base configuration object. Config DSL methods are written
    # literally per rune (the `field` helper for third-party runes is
    # CRuby-only — lib/runes/workflow/config_field.rb).
    #
    # Includes the workflow-param accessors in the class body: AOT
    # compilation has no per-object `extend`; ConfigManager sets only
    # `workflow_context` per instance.
    # ------------------------------------------------------------------
    class Config
      include Runes::WorkflowParamAccessors

      class ConfigError < Runes::Error; end
      class InvalidConfigError < ConfigError; end

      attr_reader :values

      def initialize(initial = {})
        @values = initial
      end

      # Subclasses override to validate after all config blocks have run.
      def validate!; end

      def [](key)
        @values[key]
      end

      def []=(key, value)
        @values[key] = value
      end

      # Values from `other` win; neither operand is mutated.
      def merge(other)
        self.class.new(Runes.deep_dup(@values).merge(Runes.deep_dup(other.values)))
      end

      def deep_dup
        self.class.new(Runes.deep_dup(@values))
      end

      # NOTE: the `field` DSL for third-party runes is CRuby-only
      # (lib/runes/workflow/config_field.rb) — it needs dynamic
      # define_method, which a compiled kernel does not provide.

      # --- base options (shared by every rune) --------------------------

      def async!
        @values[:async] = true
      end

      def no_async!
        @values[:async] = false
      end

      def async?
        !!@values[:async]
      end

      def abort_on_failure!
        @values[:abort_on_failure] = true
      end

      def no_abort_on_failure!
        @values[:abort_on_failure] = false
      end

      def abort_on_failure?
        @values.fetch(:abort_on_failure, true)
      end

      def working_directory(directory)
        @values[:working_directory] = directory
      end

      # Explicitly nil, not absent: a name-scoped config must be able to
      # override a broader config that set a working directory.
      def use_current_working_directory!
        @values[:working_directory] = nil
      end

      def valid_working_directory
        raw = @values[:working_directory]
        return nil if raw.nil?

        path = File.expand_path(raw.to_s)
        raise InvalidConfigError, "working directory '#{path}' does not exist" unless File.exist?(path)
        raise InvalidConfigError, "working directory '#{path}' is not a directory" unless File.directory?(path)

        path
      end

      alias continue_on_failure! no_abort_on_failure!
      alias sync! no_async!
    end

    # ------------------------------------------------------------------
    # Input: what a rune's input block configures. Lifecycle is
    # validate! -> (on failure) coerce(return_value) -> validate! -> execute.
    # ------------------------------------------------------------------
    class Input
      class InputError < Runes::Error; end
      class InvalidInputError < InputError; end

      # Subclasses raise InvalidInputError when required data is missing.
      def validate!
        raise NotImplementedError
      end

      # Optional: pull values out of the input block's return value.
      def coerce(_input_return_value)
        @coerce_ran = true
      end

      # Subclasses use this from validate! to allow a second pass with a
      # legitimately nil value after coerce has run.
      def coerce_ran?
        @coerce_ran ||= false
      end
    end

    # ------------------------------------------------------------------
    # Output: base class for rune outputs. Every output exposes `raw_text`
    # (the canonical text form) and `deep_dup`.
    # ------------------------------------------------------------------
    class Output
      # Parses the output text as JSON, permissively.
      module WithJson
        def json!
          input = raw_text
          return {} if input.nil? || input.to_s.strip.empty?

          @json ||= parse_json_with_fallbacks(input)
        end

        def json
          json!
        rescue Runes::Json::ParseError
          nil
        end

        private

        def parse_json_with_fallbacks(input)
          candidates = extract_json_candidates(input)
          candidates.each do |candidate|
            begin
              return Runes::Json.parse(candidate.strip, max_nesting: 32, symbolize_names: true)
            rescue Runes::Json::ParseError, TypeError
              next
            end
          end
          raise Runes::Json::ParseError, "Could not parse JSON from input:\n---\n#{input}\n---"
        end

        def extract_json_candidates(input)
          [
            input.strip,                                     # whole string
            *extract_code_blocks(input, "json").reverse,     # ```json (last first)
            *extract_code_blocks(input, nil).reverse,        # bare ``` (last first)
            *extract_code_blocks(input, :any).reverse,       # ```lang (last first)
            *extract_json_like_blocks(input)                 # {...} / [...] scans
          ].compact.uniq
        end

        def extract_code_blocks(input, language)
          blocks = []
          parts = input.split("```")
          (1...parts.length).step(2) do |i|
            block_with_header = parts[i]
            next unless block_with_header

            lines = block_with_header.lines
            first_line = lines.first&.strip || ""
            content = (lines[1..] || []).join
            case language
            when String
              blocks << content if first_line == language
            when nil
              blocks << content if first_line.empty?
            when :any
              blocks << content if !first_line.empty? && first_line != "json"
            end
          end
          blocks
        rescue StandardError
          []
        end

        def extract_json_like_blocks(input)
          blocks = []
          input.scan(/^[ \t]*([{\[].*?[}\]])[ \t]*$/m) { |match| blocks << match[0] }
          input.scan(/([{\[](?:[^{}\[\]]|(?:\{(?:[^{}]|\{[^{}]*\})*\})|(?:\[(?:[^\[\]]|\[[^\[\]]*\])*\]))*[}\]])/m) do |match|
            blocks << match[0]
          end
          blocks.uniq.sort_by { |block| -block.length }
        rescue StandardError
          []
        end
      end

      # Parses the output text as a number, permissively.
      module WithNumber
        def float!
          @float ||= parse_number_with_fallbacks(raw_text || "")
        end

        def float
          float!
        rescue ArgumentError
          nil
        end

        def integer!
          @integer ||= float!.round
        end

        def integer
          integer!
        rescue ArgumentError
          nil
        end

        private

        def parse_number_with_fallbacks(input)
          extract_number_candidates(input).each do |candidate|
            normalized = normalize_number_string(candidate)
            next if normalized.nil?

            begin
              return Float(normalized)
            rescue ArgumentError, TypeError
              next
            end
          end
          raise ArgumentError, "Could not parse number from input:\n---\n#{input}\n---"
        end

        def extract_number_candidates(input)
          candidates = [input.strip]
          lines = input.lines.map { |v| v.strip }.reject { |v| v.empty? }
          candidates.concat(lines.reverse)
          lines.reverse.each do |line|
            matches = line.scan(/-?[\d\s$¢£€¥.,_]+(?:[eE][+-]?\d+)?/)
            candidates.concat(matches.map { |v| v.strip }.reverse)
          end
          candidates.compact.uniq
        end

        def normalize_number_string(raw)
          normalized = raw.strip.gsub(/[\s$¢£€¥,_]/, "")
          normalized if normalized.match?(/\A-?\d+(?:\.\d*)?(?:[eE][+-]?\d+)?\z/)
        end
      end

      # Text conveniences: `text`/`lines`.
      module WithText
        def text
          raw_text.strip
        end

        def lines
          raw_text.lines.map { |v| v.strip }
        end
      end

      # The canonical text form of this output. Subclasses must implement it.
      def raw_text
        raise NotImplementedError, "#{self.class} must implement #raw_text"
      end

      # A real deep copy of the output and everything it holds. System rune
      # outputs hold an ExecutionManager; `dup` there is a shallow copy on
      # purpose so `from`/`collect`/`reduce` keep working on the copy.
      def deep_dup
        copy = dup
        instance_variables.each do |ivar|
          copy.instance_variable_set(ivar, Runes.deep_dup(instance_variable_get(ivar)))
        end
        copy
      end
    end
  end
end
