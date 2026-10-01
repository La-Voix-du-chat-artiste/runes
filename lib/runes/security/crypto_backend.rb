# frozen_string_literal: true

require_relative '../compat'

module Runes
  module Security
    # Crypto seam: the ONLY way kernel files (envelope, identity, trust
    # store, rpc_auth) touch signatures, HMAC, and key material.
    #
    # Two backends implement the same contract:
    #
    #   * CryptoBackends::OpenSSL  — CRuby, wired by
    #     lib/runes/backends/cruby.rb. Battle-tested; zero behavior change.
    #   * CryptoBackends::Native   — Runes::Native FFI primitives, wired by
    #     both spin entries (Fiddle binder under CRuby parity runs, Spinel
    #     FFI when compiled).
    #
    # Until a backend is wired, every call raises UnavailableError — a
    # missing backend is a configuration error, never a silent bypass.
    module CryptoBackend
      class UnavailableError < StandardError; end

      class MissingBackend
        MESSAGE = 'Runes::Security::CryptoBackend: no backend wired (CRuby: require runes/backends/cruby; ' \
                  'spinel: the kernel entry wires CryptoBackends::NativeBackend)'.freeze

        def self.verify(_sig, _msg, _pk)
          raise UnavailableError, MESSAGE
        end

        def self.sign(_msg, _seed)
          raise UnavailableError, MESSAGE
        end

        def self.generate_keypair
          raise UnavailableError, MESSAGE
        end

        def self.public_from_private(_seed)
          raise UnavailableError, MESSAGE
        end

        def self.hmac_sha256(_key, _msg)
          raise UnavailableError, MESSAGE
        end
      end

      def self.backend
        @backend || MissingBackend
      end

      def self.backend=(backend)
        @backend = backend
      end

      # sig64 over msg with a raw 32-byte public key -> bool (never raises).
      def self.verify(signature, message, public_key)
        backend.verify(signature.to_s, message.to_s, public_key.to_s)
      rescue StandardError
        false
      end

      # sig64 over msg with a raw 32-byte seed -> String, raises on failure.
      def self.sign(message, seed)
        backend.sign(message.to_s, seed.to_s)
      end

      # -> { seed: <32B>, pk: <32B> }
      def self.generate_keypair
        backend.generate_keypair
      end

      # raw 32-byte seed -> raw 32-byte public key; raises on failure.
      def self.public_from_private(seed)
        backend.public_from_private(seed.to_s)
      end

      # -> raw 32-byte HMAC-SHA256; raises UnavailableError when no backend.
      def self.hmac_sha256(key, message)
        backend.hmac_sha256(key.to_s, message.to_s)
      end

      # -> raw 32-byte digest; falls back to the pure facade implementation.
      def self.sha256_digest(message)
        if backend.respond_to?(:sha256_digest) && backend != MissingBackend
          backend.sha256_digest(message.to_s)
        else
          Runes::Compat.hex_decode(Runes::SHA256.hex(message.to_s))
        end
      rescue StandardError
        Runes::Compat.hex_decode(Runes::SHA256.hex(message.to_s))
      end
    end
  end
end
