# frozen_string_literal: true

module Runes
  module Security
    # A bounded, thread-safe set of "recently accepted" nonces with a TTL.
    #
    # Replay protection needs exactly one shared primitive: remember every
    # nonce you have accepted, forget them after a window, and refuse to
    # accept the same one twice inside it. Extracted from RPCAuth so the
    # signed-envelope path can use the same implementation instead of a
    # second, subtly different one (doc5.md E5-13).
    class NonceCache
      DEFAULT_TTL_S = 300
      DEFAULT_MAX = 1024

      def initialize(ttl: DEFAULT_TTL_S, max: DEFAULT_MAX)
        @ttl = Integer(ttl)
        @max = Integer(max)
        @seen = {}
        @mutex = Mutex.new
      end

      # Atomically test-and-record. Returns true the first time a nonce is
      # seen inside the TTL, false for any replay (or an empty nonce, which
      # is never accepted: there is nothing to remember).
      def check_and_record(nonce, now = Time.now.to_i)
        key = nonce.to_s
        return false if key.empty?

        @mutex.synchronize do
          prune(now)
          return false if @seen.key?(key)

          @seen[key] = now
          # Oldest-first eviction: insertion order is chronological, and the
          # TTL prune above already removed everything that expired.
          @seen.shift while @seen.size > @max
          true
        end
      end

      def size
        @mutex.synchronize { @seen.size }
      end

      private

      def prune(now)
        cutoff = now - @ttl
        @seen.delete_if { |_nonce, at| at < cutoff }
      end
    end
  end
end
