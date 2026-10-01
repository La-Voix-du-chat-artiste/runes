# frozen_string_literal: true

# Native (Runes::Native FFI) implementation of the CryptoBackend contract —
# wired by both spin entries. Under CRuby parity runs the Native functions
# are bound by the Fiddle backend against the real shared libraries; under
# Spinel they are compile-time FFI calls. Unavailable primitives surface as
# CryptoBackend::UnavailableError and fail closed upstream.
require_relative '../crypto_backend'
require_relative '../../native'

module Runes
  module Security
    module CryptoBackends
      module NativeBackend
        def self.verify(signature, message, public_key)
          Runes::Native.ed25519_verify(signature, message, public_key)
        end

        def self.sign(message, seed)
          Runes::Native.ed25519_sign(message, seed)
        rescue Runes::Native::UnavailableError => e
          raise CryptoBackend::UnavailableError, e.message
        end

        def self.generate_keypair
          Runes::Native.generate_keypair
        rescue Runes::Native::UnavailableError => e
          raise CryptoBackend::UnavailableError, e.message
        end

        def self.public_from_private(seed)
          Runes::Native.public_from_private(seed)
        rescue Runes::Native::UnavailableError => e
          raise CryptoBackend::UnavailableError, e.message
        end

        def self.hmac_sha256(key, message)
          Runes::Native.hmac_sha256(key, message)
        rescue Runes::Native::UnavailableError => e
          raise CryptoBackend::UnavailableError, e.message
        end

        def self.sha256_digest(message)
          Runes::Native.sha256_digest(message)
        rescue Runes::Native::UnavailableError
          CryptoBackend.sha256_digest(message)
        end
      end
    end
  end
end
