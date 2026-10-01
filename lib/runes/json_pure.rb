# frozen_string_literal: true

require_relative 'json_facade'
require_relative 'compat'

module Runes
  # Strict, dependency-free JSON parser and generator — the backend the
  # Spinel kernel wires in (spin/kernel.rb), and the hermetic fallback the
  # suite parity-tests against stdlib JSON. Recursive descent over a byte
  # string; raises Runes::Json::ParseError exactly where stdlib JSON would
  # refuse input.
  #
  # Deliberate parity notes (all pinned by test/spinel_subset_test.rb):
  #   * duplicate object keys: last one wins (matches stdlib);
  #   * nesting deeper than max_nesting (default 100, stdlib's default)
  #     raises ParseError (stdlib: JSON::NestingError, a ParserError); like
  #     stdlib, the outermost container does not count (parity-pinned by
  #     test/spinel_subset_test.rb);
  #   * trailing garbage after the top-level value raises;
  #   * numbers: Integer when the token has no '.'/'e'/'E', Float otherwise
  #     (large exponents yield Infinity, as stdlib does);
  #   * unpaired UTF-16 surrogates decode as '?' (stdlib passes the broken
  #     bytes through; kernel payloads never contain surrogates).
  module JSONPure
    DEFAULT_MAX_NESTING = 100
    HEX4 = /\A[0-9a-fA-F]{4}\z/

    def self.parse(text, max_nesting: nil, symbolize_names: false)
      value = Parser.new(text.to_s, max_nesting || DEFAULT_MAX_NESTING).parse
      symbolize_names ? symbolize(value) : value
    end

    # Deep-convert String keys to Symbols (stdlib's symbolize_names
    # semantics: keys only, values untouched).
    def self.symbolize(value)
      case value
      when Hash
        out = {}
        value.each { |key, val| out[key.is_a?(String) ? key.to_sym : key] = symbolize(val) }
        out
      when Array
        value.map { |element| symbolize(element) }
      else
        value
      end
    end

    # --- generator -------------------------------------------------------
    #
    # Pure value style (out = out + piece, return the accumulator) rather
    # than << mutation: a whole-program build shape exists where the
    # analyzer passes the accumulator by value instead of as a mutable
    # cell, silently dropping every <<. Reassignment is correct in both
    # shapes (and the concat-flattening optimization still applies to +).

    def self.generate(obj)
      emit(obj, String.new)
    end

    def self.emit(obj, out)
      case obj
      when nil    then out + 'null'
      when true   then out + 'true'
      when false  then out + 'false'
      when Integer then out + obj.to_s
      when Float
        raise Runes::Json::ParseError, "json: #{obj} is not JSON-serializable" if obj.nan? || obj.infinite?

        out + obj.to_s
      when String then emit_string(obj, out)
      when Array
        out = out + '['
        obj.each_with_index do |item, i|
          out = out + ',' if i.positive?
          out = emit(item, out)
        end
        out + ']'
      when Hash
        out = out + '{'
        first = true
        obj.each do |key, value|
          name = key.is_a?(Symbol) ? key.to_s : key
          unless name.is_a?(String)
            raise Runes::Json::ParseError, "json: #{key.inspect} is not a usable object key"
          end
          out = out + ',' unless first
          first = false
          out = emit_string(name, out)
          out = out + ':'
          out = emit(value, out)
        end
        out + '}'
      else
        raise Runes::Json::ParseError, "json: #{obj.class} is not JSON-serializable"
      end
    end

    ESCAPES = {
      '"' => '"', '\\' => '\\', '/' => '/',
      'b' => "\b", 'f' => "\f", 'n' => "\n", 'r' => "\r", 't' => "\t"
    }.freeze

    def self.emit_string(str, out)
      out = out + '"'
      str.to_s.each_char do |ch|
        case ch
        when '"' then out = out + '\\"'
        when '\\' then out = out + '\\\\'
        when "\n" then out = out + '\\n'
        when "\r" then out = out + '\\r'
        when "\t" then out = out + '\\t'
        when "\b" then out = out + '\\b'
        when "\f" then out = out + '\\f'
        else
          code = ch.ord
          if code < 0x20
            out = out + '\\u' + Runes::Compat.pad_left(code.to_s(16), 4)
          else
            out = out + ch
          end
        end
      end
      out + '"'
    end

    # --- parser ----------------------------------------------------------

    class Parser
      WHITESPACE = ["\t", "\n", "\r", ' '].freeze
      NUMBER_CHARS = '-+.eE0123456789'
      NUMBER_RE = /\A-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+-]?\d+)?\z/

      def initialize(text, max_nesting)
        @s = text
        @len = text.length
        @i = 0
        @max = max_nesting
        @depth = 0
      end

      def parse
        skip_ws
        value = parse_value
        skip_ws
        raise error('trailing characters after JSON value') unless @i == @len

        value
      end

      private

      def parse_value
        raise error("unexpected end of input (offset #{@i}/#{@len})") if @i >= @len

        case @s[@i]
        when '{' then parse_object
        when '[' then parse_array
        when '"' then parse_string
        when 't' then expect_word('true', true)
        when 'f' then expect_word('false', false)
        when 'n' then expect_word('null', nil)
        else parse_number
        end
      end

      def parse_object
        enter
        out = {}
        @i += 1 # '{'
        skip_ws
        if @s[@i] == '}'
          @i += 1
          leave
          return out
        end

        loop do
          skip_ws
          raise error("expected string key at #{@i}") unless @s[@i] == '"'

          key = parse_string
          skip_ws
          raise error("expected ':' at #{@i}") unless @s[@i] == ':'

          @i += 1
          skip_ws
          out[key] = parse_value
          skip_ws
          case @s[@i]
          when ','
            @i += 1
          when '}'
            @i += 1
            leave
            return out
          else
            raise error("expected ',' or '}' at #{@i}")
          end
        end
      end

      def parse_array
        enter
        out = []
        @i += 1 # '['
        skip_ws
        if @s[@i] == ']'
          @i += 1
          leave
          return out
        end

        loop do
          skip_ws
          out << parse_value
          skip_ws
          case @s[@i]
          when ','
            @i += 1
          when ']'
            @i += 1
            leave
            return out
          else
            raise error("expected ',' or ']' at #{@i}")
          end
        end
      end

      def parse_string
        @i += 1 # '"'
        out = String.new
        while @i < @len
          ch = @s[@i]
          case ch
          when '"'
            @i += 1
            return out
          when '\\'
            @i += 1
            raise error('unterminated escape') if @i >= @len

            esc = @s[@i]
            @i += 1
            if esc == 'u'
              out << parse_unicode_escape
            elsif ESCAPES.key?(esc)
              out << ESCAPES[esc]
            else
              raise error("invalid escape \\#{esc}")
            end
          else
            out << ch
            @i += 1
          end
        end
        raise error('unterminated string')
      end

      # \uXXXX, combining a surrogate pair when one follows. Unpaired
      # surrogates decode as '?' (documented parity note above).
      def parse_unicode_escape
        raise error('truncated \\u escape') if @i + 4 > @len

        hex = @s[@i, 4]
        raise error("invalid \\u escape #{hex.inspect}") unless hex.match?(HEX4)

        @i += 4
        code = hex.to_i(16)
        if code >= 0xd800 && code <= 0xdbff && @s[@i] == '\\' && @s[@i + 1] == 'u'
          low_hex = @s[@i + 2, 4]
          if low_hex && low_hex.match?(HEX4)
            low = low_hex.to_i(16)
            if low >= 0xdc00 && low <= 0xdfff
              @i += 6
              return Runes::Compat.utf8_char(((code - 0xd800) << 10) + (low - 0xdc00) + 0x10000)
            end
          end
          '?'
        elsif code >= 0xdc00 && code <= 0xdfff
          '?'
        else
          Runes::Compat.utf8_char(code)
        end
      end

      def parse_number
        start = @i
        @i += 1 while @i < @len && NUMBER_CHARS.include?(@s[@i])
        token = @s[start, @i - start]
        raise error("invalid value at #{start}") if token.empty? || !token.match?(NUMBER_RE)

        if token.include?('.') || token.include?('e') || token.include?('E')
          Float(token)
        else
          Integer(token, 10)
        end
      rescue ArgumentError
        raise error("invalid number #{token.inspect}")
      end

      def expect_word(word, value)
        raise error("invalid value at #{@i}") unless @s[@i, word.length] == word

        @i += word.length
        value
      end

      def skip_ws
        @i += 1 while @i < @len && WHITESPACE.include?(@s[@i])
      end

      def enter
        @depth += 1
        # stdlib parity (json 3.x): the outermost container does not count
        # against max_nesting — N containers raise only when N > max + 1.
        raise error("nesting deeper than #{@max}") if @depth > @max + 1
      end

      def leave
        @depth -= 1
      end

      def error(message)
        Runes::Json::ParseError.new("json: #{message}")
      end
    end
  end
end
