# frozen_string_literal: true

require_relative '../compat'
require_relative '../sha256_facade'

module Runes
  module Security
    # Minimal, pure-Ruby DER/PEM codec for Ed25519 keys — the pieces
    # Identity and TrustStore need so they compile without OpenSSL
    # (docs/spinel/spec-tier-b.md §B1):
    #
    #   PKCS#8 private  (BEGIN PRIVATE KEY):  SEQUENCE { INTEGER 0,
    #     SEQUENCE { OID 1.3.101.112 }, OCTET STRING { OCTET STRING seed32 } }
    #   SPKI public     (BEGIN PUBLIC KEY):   SEQUENCE { SEQUENCE { OID },
    #     BIT STRING 0x00 || raw32 }
    #
    # Only this tool's own key shapes are supported — a deliberately small
    # attack surface. Byte-for-byte parity with OpenSSL's output is pinned by
    # test/native_backend_test.rb (round-trips real OpenSSL keys on CRuby).
    module Ed25519Der
      ED25519_OID_DER = Runes::Compat.byte_string([0x06, 0x03, 0x2b, 0x65, 0x70]) # OID 1.3.101.112
      class DerError < StandardError; end

      # --- writing -------------------------------------------------------

      def self.private_pkcs8_der(seed32)
        wrap_sequence(
          Runes::Compat.byte_string([0x02, 0x01, 0x00]) +                # INTEGER 0
          wrap_sequence(ED25519_OID_DER) +               # AlgorithmIdentifier
          wrap_octet_string(wrap_octet_string(seed32))   # privateKey -> CurvePrivateKey
        )
      end

      def self.public_spki_der(raw32)
        wrap_sequence(
          wrap_sequence(ED25519_OID_DER) +
          Runes::Compat.byte_string([0x03, raw32.bytesize + 1, 0x00]) + raw32 # BIT STRING, 0 unused bits
        )
      end

      def self.private_pem(seed32)
        armor('PRIVATE KEY', b64(private_pkcs8_der(seed32)))
      end

      def self.public_pem(raw32)
        armor('PUBLIC KEY', b64(public_spki_der(raw32)))
      end

      # --- reading -------------------------------------------------------

      # PEM (either kind) -> { kind: :private, seed: <32B> } or
      # { kind: :public, raw: <32B> }. Raises DerError on anything else.
      def self.parse_pem(pem)
        text = pem.to_s
        if text.include?('-----BEGIN PRIVATE KEY-----')
          body = text[/-----BEGIN PRIVATE KEY-----\n?(.*?)-----END PRIVATE KEY-----/m, 1]
          raise DerError, 'malformed private key PEM' if body.nil?

          { kind: :private, seed: parse_private_pkcs8(unb64(body)) }
        elsif text.include?('-----BEGIN PUBLIC KEY-----')
          body = text[/-----BEGIN PUBLIC KEY-----\n?(.*?)-----END PUBLIC KEY-----/m, 1]
          raise DerError, 'malformed public key PEM' if body.nil?

          { kind: :public, raw: parse_public_spki(unb64(body)) }
        else
          raise DerError, 'not a PEM key'
        end
      end

      def self.parse_private_pkcs8(der)
        content, rest = read_tlv(der, 0x30)
        raise DerError, 'malformed private key DER' if content.nil? || rest != der.bytesize

        int_data, pos = read_tlv(content, 0x02, 0)
        raise DerError, 'malformed private key DER' if int_data.nil? || int_data != "\x00"

        alg, pos = read_tlv(content, 0x30, pos)
        raise DerError, 'expected Ed25519 key' if alg != ED25519_OID_DER

        octets, pos = read_tlv(content, 0x04, pos)
        raise DerError, 'malformed private key DER' if octets.nil?

        seed, inner_rest = read_tlv(octets, 0x04, 0)
        raise DerError, 'malformed private key DER' if seed.nil? || inner_rest != octets.bytesize || seed.bytesize != 32

        seed
      end

      def self.parse_public_spki(der)
        content, rest = read_tlv(der, 0x30)
        raise DerError, 'malformed public key DER' if content.nil? || rest != der.bytesize

        alg, pos = read_tlv(content, 0x30, 0)
        raise DerError, 'expected Ed25519 key' if alg != ED25519_OID_DER

        bits, = read_tlv(content, 0x03, pos)
        raise DerError, 'malformed public key DER' if bits.nil? || bits.bytesize != 33 || bits.getbyte(0) != 0

        bits[1..-1]
      end

      # --- primitives ----------------------------------------------------

      def self.wrap_sequence(content)
        Runes::Compat.byte_string([0x30]) + length_bytes(content.bytesize) + content
      end

      def self.wrap_octet_string(content)
        Runes::Compat.byte_string([0x04]) + length_bytes(content.bytesize) + content
      end

      # DER length, short and long form (up to 4 length bytes).
      def self.length_bytes(n)
        return Runes::Compat.byte_string([n]) if n < 0x80

        bytes = []
        while n.positive?
          bytes.unshift(n & 0xff)
          n >>= 8
        end
        Runes::Compat.byte_string([0x80 | bytes.size]) + Runes::Compat.byte_string(bytes)
      end

      # Read a TLV of the expected tag at offset; returns [content, offset_after].
      def self.read_tlv(der, tag, offset = 0)
        return [nil, nil] if der.nil? || offset >= der.bytesize || der.getbyte(offset) != tag

        first_len = der.getbyte(offset + 1)
        raise DerError, 'malformed DER length' if first_len.nil?

        if first_len < 0x80
          header = 2
          length = first_len
        else
          count = first_len & 0x7f
          raise DerError, 'malformed DER length' if count.zero? || count > 4

          length = 0
          count.times { |i| length = (length << 8) | der.getbyte(offset + 2 + i) }
          header = 2 + count
        end
        content = der.byteslice(offset + header, length)
        raise DerError, 'truncated DER' if content.nil? || content.bytesize != length

        [content, offset + header + length]
      end

      def self.b64(bytes)
        Runes::Compat.base64_encode(bytes)
      end

      def self.unb64(text)
        Runes::Compat.base64_decode(text)
      rescue ArgumentError
        raise DerError, 'malformed base64 in PEM'
      end

      def self.armor(label, b64_text)
        lines = []
        b64_text.scan(/.{1,64}/) { |chunk| lines << chunk }
        "-----BEGIN #{label}-----\n#{lines.join("\n")}\n-----END #{label}-----\n"
      end
    end
  end
end
