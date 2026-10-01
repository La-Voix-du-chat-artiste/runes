# frozen_string_literal: true

# OpenSSL implementation of the Runes::Security::CryptoBackend contract —
# the CRuby backend, wired by lib/runes/backends/cruby.rb. Keys are handled
# as raw 32-byte strings at the boundary (the wire format the kernel uses),
# converted to/from OpenSSL objects here.
require 'openssl'

require_relative '../crypto_backend'

module Runes
  module Security
    module CryptoBackends
      module OpenSSLBackend
        ALGORITHM = 'ED25519'

        def self.verify(signature, message, public_key)
          key = OpenSSL::PKey.new_raw_public_key(ALGORITHM, public_key)
          key.verify(nil, signature, message)
        rescue OpenSSL::PKey::PKeyError, ArgumentError, TypeError
          false
        end

        def self.sign(message, seed)
          key = OpenSSL::PKey.new_raw_private_key(ALGORITHM, seed)
          key.sign(nil, message)
        rescue OpenSSL::PKey::PKeyError, ArgumentError, TypeError => e
          raise CryptoBackend::UnavailableError, "OpenSSL sign failed: #{e.class}"
        end

        def self.generate_keypair
          key = OpenSSL::PKey.generate_key(ALGORITHM)
          { seed: key.raw_private_key, pk: key.raw_public_key }
        rescue OpenSSL::PKey::PKeyError => e
          raise CryptoBackend::UnavailableError, "key generation failed: #{e.class}"
        end

        def self.public_from_private(seed)
          key = OpenSSL::PKey.new_raw_private_key(ALGORITHM, seed)
          key.raw_public_key
        rescue OpenSSL::PKey::PKeyError, ArgumentError, TypeError => e
          raise CryptoBackend::UnavailableError, "public derivation failed: #{e.class}"
        end

        def self.hmac_sha256(key, message)
          OpenSSL::HMAC.digest(OpenSSL::Digest.new('SHA256'), key, message)
        rescue OpenSSL::OpenSSLError => e
          raise CryptoBackend::UnavailableError, "HMAC failed: #{e.class}"
        end

        def self.sha256_digest(message)
          OpenSSL::Digest::SHA256.digest(message)
        end
      end
    end
  end
end
