# frozen_string_literal: true

require 'json'
require 'openssl'
require 'digest'
require 'securerandom'

require_relative 'nonce_cache'

module Runes
  module Security
    # Freshness for the tool-RPC request (S5-4/E5-13).
    #
    # The dispatcher's `runes/tools/+/request` topic is an execution API
    # guarded by a shared secret. A bare shared secret authenticates but
    # does not expire: a single captured request replays forever. This
    # module adds a `{ts, nonce, mac}` triple:
    #
    #   args = RPCAuth.sign(secret, 'write_file', { 'path' => 'x', 'content' => 'y' })
    #   # => { 'path' => 'x', 'content' => 'y',
    #   #      'ts' => 1234, 'nonce' => 'ab…', 'mac' => '…' }
    #
    # The MAC is HMAC-SHA256 over `tool_id`, the timestamp, the nonce and a
    # SHA-256 digest of the request body (every field except
    # token/ts/nonce/mac, keys sorted). The receiver rejects anything
    # outside MAX_SKEW_S of its clock and remembers every accepted nonce
    # for NONCE_TTL_S so a captured request cannot be replayed inside the
    # window.
    module RPCAuth
      MAX_SKEW_S = 120
      NONCE_TTL_S = 300
      MAX_SEEN_NONCES = 1024
      AUTH_FIELDS = %w[token ts nonce mac].freeze

      # Kept as a constant so existing callers (and tests) that reference
      # RPCAuth::NonceCache keep working; the implementation is shared with
      # the signed-envelope replay guard.
      NonceCache = Runes::Security::NonceCache

      class << self
        # Deterministic digest of the request body without auth fields.
        def body_digest(args)
          payload = args.each_with_object({}) do |(key, value), out|
            name = key.to_s
            out[name] = value unless AUTH_FIELDS.include?(name)
          end
          Digest::SHA256.hexdigest(JSON.generate(payload.sort.to_h))
        rescue JSON::GeneratorError, TypeError
          # Non-JSON values (only possible for in-process callers):
          # Hash#inspect is deterministic for the JSON-native types.
          Digest::SHA256.hexdigest(payload.sort.to_h.inspect)
        end

        def mac(secret, tool_id, ts, nonce, args)
          message = "#{tool_id}\n#{ts}\n#{nonce}\n#{body_digest(args)}"
          OpenSSL::HMAC.hexdigest('SHA256', secret.to_s, message)
        end

        # Add a fresh ts/nonce/mac to a copy of `args`. `token` is added by
        # the caller (it is the shared secret itself, kept separate).
        def sign(secret, tool_id, args, ts: Time.now.to_i, nonce: SecureRandom.hex(16))
          args.merge(
            'ts' => Integer(ts),
            'nonce' => nonce.to_s,
            'mac' => mac(secret, tool_id, ts, nonce, args)
          )
        end

        # True only when the request is authentic, fresh, and not a replay.
        # A successful check consumes the nonce.
        def fresh?(secret, tool_id, args, cache:, now: Time.now.to_i)
          ts = begin
            Integer(args['ts'].to_s, 10)
          rescue ArgumentError, TypeError
            nil
          end
          nonce = args['nonce'].to_s
          supplied = args['mac'].to_s
          return false if ts.nil? || nonce.empty? || supplied.empty?
          return false if (now - ts).abs > MAX_SKEW_S
          return false unless secure_compare(supplied, mac(secret, tool_id, ts, nonce, args))

          cache.check_and_record(nonce, now)
        end

        # Constant-time string comparison (same shape as the secret check).
        def secure_compare(left, right)
          a = left.to_s.b
          b = right.to_s.b
          return false unless a.bytesize == b.bytesize

          diff = 0
          a.bytes.each_with_index { |byte, i| diff |= byte ^ b.getbyte(i) }
          diff.zero?
        end
      end
    end
  end
end
