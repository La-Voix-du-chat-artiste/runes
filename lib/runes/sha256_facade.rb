# frozen_string_literal: true

require_relative 'compat'

module Runes
  # SHA-256 facade with a pure-Ruby default.
  #
  # Kernel code (DocStore content addressing) never says ::Digest — it says
  # Runes::SHA256.hex. Named without a Digest module on purpose: a Runes::
  # Digest would shadow ::Digest for every file under the Runes namespace
  # (trust_store, identity, rpc_auth all use ::Digest::SHA256).
  #
  # The default backend below is a self-contained SHA-256 (FIPS 180-4, no
  # stdlib), so the kernel compiles and runs hermetic anywhere;
  # lib/runes/backends/cruby.rb installs the OpenSSL fast path under CRuby.
  # Both are pinned to the same vectors by the test suite.
  module SHA256
    def self.backend
      @backend ||= Pure
    end

    def self.backend=(backend)
      @backend = backend
    end

    def self.hex(str)
      backend.hex(str)
    end

    # FIPS 180-4 SHA-256 over bytes. Every intermediate is masked to 32 bits
    # so no value exceeds a 63-bit signed word (Spinel's fixed-width ints).
    module Pure
      K = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
      ].freeze
      M32 = 0xffffffff

      def self.hex(message)
        text = message.to_s
        bytes = []
        bi = 0
        while bi < text.bytesize
          bytes << text.getbyte(bi)
          bi += 1
        end
        bit_len = bytes.size * 8
        bytes << 0x80
        bytes << 0x00 while (bytes.size % 64) != 56
        7.downto(0) { |i| bytes << ((bit_len >> (i * 8)) & 0xff) }

        h = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]
        offset = 0
        while offset < bytes.size
          w = []
          16.times do |i|
            j = offset + i * 4
            w << ((bytes[j] << 24) | (bytes[j + 1] << 16) | (bytes[j + 2] << 8) | bytes[j + 3])
          end
          (16..63).each do |i|
            x = w[i - 15]
            s0 = ror(x, 7) ^ ror(x, 18) ^ (x >> 3)
            y = w[i - 2]
            s1 = ror(y, 17) ^ ror(y, 19) ^ (y >> 10)
            w << ((w[i - 16] + s0 + w[i - 7] + s1) & M32)
          end

          a, b, c, d, e, f, g, hh = h
          64.times do |i|
            s1 = ror(e, 6) ^ ror(e, 11) ^ ror(e, 25)
            ch = (e & f) ^ ((~e & M32) & g)
            temp1 = (hh + s1 + ch + K[i] + w[i]) & M32
            s0 = ror(a, 2) ^ ror(a, 13) ^ ror(a, 22)
            maj = (a & b) ^ (a & c) ^ (b & c)
            temp2 = (s0 + maj) & M32
            hh = g
            g = f
            f = e
            e = (d + temp1) & M32
            d = c
            c = b
            b = a
            a = (temp1 + temp2) & M32
          end

          h[0] = (h[0] + a) & M32
          h[1] = (h[1] + b) & M32
          h[2] = (h[2] + c) & M32
          h[3] = (h[3] + d) & M32
          h[4] = (h[4] + e) & M32
          h[5] = (h[5] + f) & M32
          h[6] = (h[6] + g) & M32
          h[7] = (h[7] + hh) & M32
          offset += 64
        end

        h.map { |word| Runes::Compat.pad_left(word.to_s(16), 8) }.join
      end

      def self.ror(x, n)
        ((x >> n) | (x << (32 - n))) & M32
      end
    end
  end
end
