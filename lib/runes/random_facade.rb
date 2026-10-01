# frozen_string_literal: true

require_relative 'compat'

module Runes
  # Random facade. Two hard rules:
  #
  #   * `hex`/`bytes` default backend (PRNGPure) is for ids and content
  #     addressing ONLY — never nonces, keys, or signatures as produced by
  #     the pure kernel;
  #   * `bytes` from a CSPRNG backend (SecureRandom under CRuby;
  #     arc4random/getrandom FFI under Spinel) IS the nonce/key source for
  #     envelope freshness and key generation (docs/spinel/spec-tier-b.md §B2).
  module Random
    def self.hex(n)
      Runes::Compat.hex_encode(bytes(n))
    end

    def self.bytes(n)
      backend.bytes(n)
    end

    def self.backend
      @backend ||= PRNGPure
    end

    def self.backend=(backend)
      @backend = backend
    end

    # xorshift32 (Marsaglia) with a Mutex: fast, deterministic quality is
    # irrelevant for ids, and correct under Spinel's no-GVL threads. All
    # intermediates stay under 2^45, well inside a 63-bit word.
    module PRNGPure
      M32 = 0xffffffff

      @mutex = Mutex.new
      # Microsecond wall clock xored with the golden-ratio constant: enough
      # spread for per-process id generation (never cryptographic — that is
      # the CSPRNG backend's job). No Process/object_id: both are either
      # absent or poly-typed on a compiled runtime.
      @state = ((Time.now.to_f * 1_000_000).to_i ^ 0x9e3779b9) & M32

      def self.bytes(n)
        target = n.to_i
        raise ArgumentError, 'random_bytes: bad size' unless target.positive?

        out = String.new
        while out.length < target
          v = step32
          4.times do |i|
            break if out.length >= target
            out << (((v >> (i * 8)) & 0xff).chr)
          end
        end
        out
      end

      def self.step32
        @mutex.synchronize do
          x = @state
          x ^= (x << 13) & M32
          x ^= x >> 17
          x ^= (x << 5) & M32
          @state = x & M32
        end
      end
    end
  end
end
