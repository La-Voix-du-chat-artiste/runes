# frozen_string_literal: true

module Runes
  # JSON facade: the one JSON surface the kernel is allowed to touch.
  #
  # Spinel ships no json stdlib, so kernel code never says ::JSON — it says
  # Runes::Json. (Named "Json", not "JSON", on purpose: a Runes::JSON module
  # would shadow ::JSON for every file under the Runes namespace and break
  # the outer shell's ::JSON references.) Under CRuby the backend is stdlib
  # JSON (wired by lib/runes/backends/cruby.rb); under a compiled kernel the
  # backend is Runes::JSONPure (wired by spin/kernel.rb). Both honour the
  # same contract:
  #
  #   Runes::Json.parse(str, max_nesting: nil, symbolize_names: false)
  #     -> Hash/Array/scalars
  #     raises Runes::Json::ParseError on malformed input or excess nesting
  #   Runes::Json.generate(obj) -> String
  #
  # Keeping this seam small is what lets the whole kernel compile without
  # waiting for an FFI JSON library.
  module Json
    class ParseError < StandardError; end

    # The backend object responds to parse(str, max_nesting:, symbolize_names:)
    # and generate(obj).
    # Nil backend is a loud configuration error, never a silent skip.
    def self.backend
      @backend
    end

    def self.backend=(backend)
      @backend = backend
    end

    def self.parse(str, max_nesting: nil, symbolize_names: false)
      ensure_backend!
      @backend.parse(str, max_nesting: max_nesting, symbolize_names: symbolize_names)
    rescue ParseError
      raise
    rescue StandardError => e
      # A backend that leaks its own error types (stdlib JSON::ParserError,
      # a future FFI layer's codes) is normalized so callers rescue one type.
      raise ParseError, e.message
    end

    def self.generate(obj)
      ensure_backend!
      @backend.generate(obj)
    rescue ParseError
      raise
    rescue StandardError => e
      raise ParseError, e.message
    end

    def self.ensure_backend!
      return unless @backend.nil?

      raise ParseError, 'Runes::Json: no backend configured (CRuby: require runes/backends/cruby; spinel: the kernel entry wires JSONPure)'
    end
  end
end
