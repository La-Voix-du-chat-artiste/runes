# frozen_string_literal: true

require_relative 'nonce_cache'
require_relative 'crypto_backend'
require_relative '../compat'
require_relative '../json_facade'
require_relative '../random_facade'

module Runes
  module Security
    # Raised for malformed / non-canonical payloads before any signature
    # work happens.
    class EnvelopeError < StandardError; end

    # Raised by Envelope.verify! for every authentication failure. The
    # machine-readable #reason is one of:
    #   :missing_signature  no sig/alg/kid triple
    #   :unknown_key        no trusted key exists for the envelope's kid
    #   :bad_signature      signature does not match the canonical payload
    #   :malformed          wrong shape, unsupported alg, bad base64/length
    #   :missing_freshness  freshness required, but ts/nonce absent
    #   :stale              ts outside the accepted clock window
    #   :replayed           this nonce was already accepted inside the window
    # Messages never embed key material or the payload body.
    class VerificationError < EnvelopeError
      REASONS = %i[missing_signature unknown_key bad_signature malformed
                   missing_freshness stale replayed].freeze

      attr_reader :reason

      def initialize(reason, message = nil)
        @reason = reason
        raise ArgumentError, "unknown verification reason #{reason.inspect}" unless REASONS.include?(reason)

        super(message || "envelope verification failed: #{reason}")
      end
    end

    # Canonical serialisation + Ed25519 signing/verification for MQTT
    # payloads.
    #
    #   signed = Runes::Security::Envelope.sign({'prompt' => 'hi'}, identity)
    #   payload = Runes::Security::Envelope.verify!(signed, trust_store)
    #
    # The signed bytes are the canonical form of the payload WITHOUT the
    # three signature fields, so key order and whitespace can never change
    # a signature and no caller can smuggle data through the signature
    # metadata.
    module Envelope
      ALGORITHM = 'ed25519'
      SIG_FIELD = 'sig'
      ALG_FIELD = 'alg'
      KID_FIELD = 'kid'
      SIGNATURE_FIELDS = [SIG_FIELD, ALG_FIELD, KID_FIELD].freeze
      ED25519_SIGNATURE_BYTES = 64

      # Optional freshness fields. They live INSIDE the signed payload, so a
      # relay cannot alter or strip them without breaking the signature.
      TS_FIELD = 'ts'
      NONCE_FIELD = 'nonce'
      FRESHNESS_FIELDS = [TS_FIELD, NONCE_FIELD].freeze
      # How far a timestamp may be from the verifier's clock.
      MAX_AGE_S = 120

      class << self
        # Deterministic canonical bytes for a payload hash:
        #   * object keys sorted by byte order, nested hashes too
        #   * no insignificant whitespace
        #   * values restricted to String / Integer / true / false / nil / Hash
        #
        # Anything else (Float, Symbol value, Array, Time, …) raises
        # EnvelopeError: silently stringifying two different Ruby values to
        # the same bytes would make signature verification ambiguous.
        def canonical(payload_hash)
          unless payload_hash.is_a?(Hash)
            raise EnvelopeError, "canonical: expected a Hash, got #{payload_hash.class}"
          end

          canonical_value(payload_hash, '')
        end

        # Return a new hash: the payload plus sig/alg/kid. The signature
        # covers canonical(payload) — i.e. WITHOUT those three fields — so
        # an existing signature on the input is stripped and replaced.
        def sign(payload_hash, identity, fresh: false, ts: Time.now.to_i,
                 nonce: nil)
          unless payload_hash.is_a?(Hash)
            raise EnvelopeError, "sign: expected a Hash payload, got #{payload_hash.class}"
          end
          unless identity.respond_to?(:sign) && identity.respond_to?(:fingerprint)
            raise EnvelopeError, 'sign: an Identity-like object is required'
          end

          payload = strip_signature(payload_hash)
          if fresh
            # Signed, so a relay cannot refresh an old envelope to make it
            # look new: changing ts or nonce invalidates the signature.
            freshness = nonce.nil? ? Runes::Random.hex(16) : nonce.to_s
            payload = payload.merge(TS_FIELD => Integer(ts), NONCE_FIELD => freshness)
          end
          signature = identity.sign(canonical(payload))
          payload.merge(
            SIG_FIELD => encode_signature(signature),
            ALG_FIELD => ALGORITHM,
            KID_FIELD => identity.fingerprint.to_s
          )
        end

        # Authenticate a signed hash against a TrustStore and return the
        # payload without sig/alg/kid.
        #
        # Fails closed at every step. When the store has no keys,
        # #key_for returns nil and this raises :unknown_key — verification
        # never degrades into "trust everything".
        #
        # @raise [VerificationError]
        # @param require_fresh [Boolean] refuse an envelope with no ts/nonce
        # @param max_age [Integer] accepted clock skew, in seconds
        # @param replay_guard [#check_and_record, nil] consumes the nonce;
        #   pass a Runes::Security::NonceCache to make replay impossible
        def verify!(signed_hash, trust_store, require_fresh: false,
                    max_age: MAX_AGE_S, replay_guard: nil, now: Time.now.to_i)
          unless signed_hash.is_a?(Hash)
            raise VerificationError.new(:malformed, "verify: expected a Hash, got #{signed_hash.class}")
          end
          unless trust_store.respond_to?(:key_for)
            raise VerificationError.new(:malformed, 'verify: a TrustStore-like object is required (fail closed)')
          end

          # Collect ALL missing fields before raising (non-short-circuiting)
          # so the failure class does not depend on which field was checked
          # first.
          present = SIGNATURE_FIELDS.select { |field| field_present?(signed_hash, field) }
          missing = SIGNATURE_FIELDS - present
          unless missing.empty?
            raise VerificationError.new(
              :missing_signature,
              "unsigned envelope: missing #{missing.join(', ')} (present: #{present.join(', ')})"
            )
          end

          alg = fetch_field(signed_hash, ALG_FIELD).to_s
          unless alg == ALGORITHM
            raise VerificationError.new(:malformed, "unsupported envelope alg #{alg.inspect} (expected #{ALGORITHM})")
          end

          signature = decode_signature(fetch_field(signed_hash, SIG_FIELD))
          if signature.bytesize != ED25519_SIGNATURE_BYTES
            raise VerificationError.new(
              :malformed, "malformed signature length #{signature.bytesize} (expected #{ED25519_SIGNATURE_BYTES})"
            )
          end

          kid = fetch_field(signed_hash, KID_FIELD).to_s
          key = trust_store.key_for(kid)
          if key.nil?
            raise VerificationError.new(
              :unknown_key, "no trusted key for kid #{kid.inspect} (#{trust_store.respond_to?(:agent_ids) ? trust_store.agent_ids.length : 0} trusted)"
            )
          end

          payload = strip_signature(signed_hash)
          valid = verify_with(key, signature, canonical(payload))
          unless valid
            raise VerificationError.new(:bad_signature, "signature does not match payload for kid #{kid.inspect}")
          end

          check_freshness!(payload, require_fresh: require_fresh, max_age: max_age,
                                   replay_guard: replay_guard, now: now)

          payload
        end

        # Freshness is checked AFTER the signature, so an attacker cannot use
        # a forged ts/nonce to influence anything, and the nonce is consumed
        # only for a payload that verified.
        def check_freshness!(payload, require_fresh:, max_age:, replay_guard:, now:)
          ts = payload[TS_FIELD]
          nonce = payload[NONCE_FIELD].to_s

          if ts.nil? || nonce.empty?
            if require_fresh
              raise VerificationError.new(
                :missing_freshness,
                "envelope carries no #{FRESHNESS_FIELDS.join('/')}; replay cannot be ruled out"
              )
            end
            return true
          end

          begin
            stamp = Integer(ts.to_s, 10)
          rescue ArgumentError, TypeError
            raise VerificationError.new(:malformed, "envelope #{TS_FIELD} is not an integer")
          end

          if (now - stamp).abs > max_age.to_i
            raise VerificationError.new(
              :stale, "envelope is #{(now - stamp).abs}s from the clock (limit #{max_age}s)"
            )
          end

          return true if replay_guard.nil?

          unless replay_guard.check_and_record(nonce, now)
            raise VerificationError.new(:replayed, 'this envelope nonce has already been accepted')
          end

          true
        end

        # True when all three signature fields are present and non-empty.
        def signed?(hash)
          return false unless hash.is_a?(Hash)

          SIGNATURE_FIELDS.all? { |field| field_present?(hash, field) }
        end

        # A copy of the payload without sig/alg/kid. Key class (String or
        # Symbol) is preserved; the returned hash never aliases the input.
        def strip_signature(hash)
          return {} unless hash.is_a?(Hash)

          out = {}
          hash.each do |key, value|
            out[key] = value unless SIGNATURE_FIELDS.include?(key.to_s)
          end
          out
        end

        # The algorithm label this module signs with.
        def algorithm
          ALGORITHM
        end

        private

        def canonical_value(value, path)
          case value
          when Hash
            canonical_hash(value, path)
          when String
            encode_string(value, path)
          when Integer
            value.to_s
          when true then 'true'
          when false then 'false'
          when nil then 'null'
          else
            raise EnvelopeError,
                  "canonical: unsupported value #{value.class} at #{path.empty? ? '<root>' : path} " \
                  '(only String, Integer, true/false, nil and nested Hashes are allowed)'
          end
        end

        def canonical_hash(hash, path)
          pairs = hash.map do |key, value|
            unless key.is_a?(String) || key.is_a?(Symbol)
              raise EnvelopeError,
                    "canonical: unsupported key #{key.class} at #{path.empty? ? '<root>' : path} " \
                    '(only String/Symbol keys are allowed)'
            end
            [key.to_s, value]
          end

          seen = {}
          pairs.each do |key, _|
            raise EnvelopeError, "canonical: duplicate key #{key.inspect} at #{path}" if seen[key]

            seen[key] = true
          end

          inner = pairs.sort_by { |v| v.first }.map do |key, value|
            "#{encode_string(key, path)}:#{canonical_value(value, path.empty? ? key : "#{path}.#{key}")}"
          end.join(',')
          "{#{inner}}"
        end

        def encode_string(value, path)
          Runes::Json.generate(value)
        rescue Runes::Json::ParseError, Encoding::UndefinedConversionError, Encoding::InvalidByteSequenceError => e
          raise EnvelopeError, "canonical: non-UTF8 string at #{path.empty? ? '<root>' : path}: #{e.class}"
        end

        def field_present?(hash, field)
          raw = fetch_field(hash, field)
          !raw.nil? && !(raw.respond_to?(:empty?) && raw.empty?)
        end

        def fetch_field(hash, field)
          if hash.key?(field)
            hash[field]
          elsif hash.key?(field.to_sym)
            hash[field.to_sym]
          end
        end

        # Strict RFC 4648 base64 (no newlines). Implemented with
        # Array#pack/String#unpack because `base64` is a bundled gem in
        # Ruby >= 3.4 and may be unavailable under Bundler.
        def encode_signature(signature)
          Runes::Compat.base64_encode(signature)
        end

        def decode_signature(raw)
          text = raw.to_s
          unless text.match?(%r{\A[A-Za-z0-9+/]*={0,2}\z}) && text.length.modulo(4).zero? && !text.empty?
            raise VerificationError.new(:malformed, 'malformed signature encoding (expected base64)')
          end

          Runes::Compat.base64_decode(text)
        rescue ArgumentError, TypeError
          raise VerificationError.new(:malformed, 'malformed signature encoding (expected base64)')
        end

        def verify_with(key, signature, bytes)
          # The key is the peer's raw 32-byte Ed25519 public key (see
          # TrustStore#key_for). Verification itself goes through the
          # CryptoBackend seam so this file stays OpenSSL-free; a failure or
          # a missing backend means "not verified", never an exception.
          Runes::Security::CryptoBackend.verify(signature, bytes, key)
        end
      end
    end
  end
end
