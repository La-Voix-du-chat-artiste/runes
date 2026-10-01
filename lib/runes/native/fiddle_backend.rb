# frozen_string_literal: true

# CRuby binder for Runes::Native via stdlib Fiddle — the verification path
# for the exact C functions the Spinel FFI declarations bind (same shared
# libraries, same signatures; docs/spinel/spec-tier-b.md). Never loaded by
# the Spinel kernel entry (Fiddle is CRuby-only) — spin/kernel_cruby.rb and
# the harness self-check load it instead.
require 'fiddle'

require_relative '../native'

module Runes
  module Native
    module FiddleBackend
      TYPES = {
        int: Fiddle::TYPE_INT,
        ptr: Fiddle::TYPE_VOIDP,
        size_t: Fiddle::TYPE_SIZE_T,
        long: Fiddle::TYPE_LONG,
        void: Fiddle::TYPE_VOID
      }.freeze

      CRYPTO_CANDIDATES = [
        ENV['RUNES_CRYPTO_LIB'],
        '/opt/homebrew/opt/openssl@3/lib/libcrypto.3.dylib',
        '/usr/local/opt/openssl@3/lib/libcrypto.3.dylib',
        '/usr/lib/libcrypto.dylib',
        'libcrypto.4.dylib', 'libcrypto.3.dylib', 'libcrypto.dylib',
        'libcrypto.so.3', 'libcrypto.so'
      ].compact.freeze

      SODIUM_CANDIDATES = [
        ENV['RUNES_SODIUM_LIB'],
        '/opt/homebrew/lib/libsodium.dylib',
        '/usr/local/lib/libsodium.dylib',
        'libsodium.dylib', 'libsodium.so.26', 'libsodium.so.23', 'libsodium.so'
      ].compact.freeze

      class << self
        # Load what is available, bind every function in MANIFEST the
        # library provides, and install normalized lambdas. Missing
        # libraries are not an error here: availability is answered lazily
        # per primitive (Runes::Native.installed?).
        def load!
          fns = {}
          crypto = open_first(CRYPTO_CANDIDATES)
          sodium = open_first(SODIUM_CANDIDATES)

          bind_crypto(fns, crypto) if crypto
          bind_sodium(fns, sodium) if sodium
          bind_libc(fns)

          Runes::Native.install!(fns)
          fns
        end

        def available?(what)
          case what
          when :ed25519 then Runes::Native.installed?('ed25519_verify')
          when :hmac then Runes::Native.installed?('hmac_sha256')
          when :random then Runes::Native.installed?('random_bytes')
          else false
          end
        end

        private

        def open_first(candidates)
          candidates.each do |name|
            handle = begin
              Fiddle::Handle.new(name)
            rescue Fiddle::DLError
              nil
            end
            return handle if handle
          end
          nil
        end

        def binder(handle)
          lambda do |c_name|
            spec = MANIFEST[c_name]
            return nil if spec.nil?

            addr = handle[c_name]
            Fiddle::Function.new(addr, spec[:args].map { |a| TYPES.fetch(a) }, TYPES.fetch(spec[:ret]))
          rescue Fiddle::DLError
            nil
          end
        end

        def bind_crypto(fns, handle)
          bind = binder(handle)
          evp_new_pub = bind.call('EVP_PKEY_new_raw_public_key')
          evp_new_priv = bind.call('EVP_PKEY_new_raw_private_key')
          evp_get_raw_pub = bind.call('EVP_PKEY_get_raw_public_key')
          md_ctx_new = bind.call('EVP_MD_CTX_new')
          md_ctx_free = bind.call('EVP_MD_CTX_free')
          verify_init = bind.call('EVP_DigestVerifyInit')
          verify = bind.call('EVP_DigestVerify')
          sign_init = bind.call('EVP_DigestSignInit')
          sign = bind.call('EVP_DigestSign')
          pkey_free = bind.call('EVP_PKEY_free')
          hmac = bind.call('HMAC')
          evp_sha256 = bind.call('EVP_sha256')
          sha256 = bind.call('SHA256')
          return unless evp_new_pub && verify_init && verify && sign_init && sign

          fns['ed25519_verify'] = lambda do |sig, msg, pk|
            pkey = evp_new_pub.call(EV_PKEY_ED, nil, pk, pk.bytesize)
            next false if pkey.nil? || pkey.null?

            begin
              ctx = md_ctx_new.call
              next false if ctx.nil? || ctx.null?

              begin
                next false unless verify_init.call(ctx, nil, nil, nil, pkey) == 1

                verify.call(ctx, sig, sig.bytesize, msg, msg.bytesize) == 1
              ensure
                md_ctx_free.call(ctx)
              end
            ensure
              pkey_free.call(pkey)
            end
          end

          fns['ed25519_sign'] = lambda do |msg, seed|
            pkey = evp_new_priv.call(EV_PKEY_ED, nil, seed, seed.bytesize)
            raise UnavailableError, 'EVP_PKEY_new_raw_private_key failed' if pkey.nil? || pkey.null?

            begin
              ctx = md_ctx_new.call
              raise UnavailableError, 'EVP_MD_CTX_new failed' if ctx.nil? || ctx.null?

              begin
                raise UnavailableError, 'EVP_DigestSignInit failed' unless sign_init.call(ctx, nil, nil, nil, pkey) == 1

                sigbuf = Fiddle::Pointer.malloc(64)
                siglen = Fiddle::Pointer.malloc(Fiddle::SIZEOF_SIZE_T)
                siglen[0, Fiddle::SIZEOF_SIZE_T] = [64].pack(Fiddle::SIZEOF_SIZE_T == 8 ? 'Q' : 'L')
                raise UnavailableError, 'EVP_DigestSign failed' unless sign.call(ctx, sigbuf, siglen, msg, msg.bytesize) == 1

                sigbuf.to_s(64)
              ensure
                md_ctx_free.call(ctx)
              end
            ensure
              pkey_free.call(pkey)
            end
          end

          if evp_get_raw_pub
            fns['public_from_private'] = lambda do |seed|
              pkey = evp_new_priv.call(EV_PKEY_ED, nil, seed, seed.bytesize)
              raise UnavailableError, 'EVP_PKEY_new_raw_private_key failed' if pkey.nil? || pkey.null?

              begin
                buf = Fiddle::Pointer.malloc(32)
                len = Fiddle::Pointer.malloc(Fiddle::SIZEOF_SIZE_T)
                len[0, Fiddle::SIZEOF_SIZE_T] = [32].pack(Fiddle::SIZEOF_SIZE_T == 8 ? 'Q' : 'L')
                raise UnavailableError, 'EVP_PKEY_get_raw_public_key failed' unless evp_get_raw_pub.call(pkey, buf, len) == 1

                buf.to_s(32)
              ensure
                pkey_free.call(pkey)
              end
            end
          end

          if hmac && evp_sha256
            fns['hmac_sha256'] = lambda do |key, msg|
              out = Fiddle::Pointer.malloc(32)
              outlen = Fiddle::Pointer.malloc(Fiddle::SIZEOF_SIZE_T)
              result = hmac.call(evp_sha256.call, key, key.bytesize, msg, msg.bytesize, out, outlen)
              raise UnavailableError, 'HMAC failed' if result.null?

              out.to_s(32)
            end
          end

          if sha256
            fns['sha256_digest'] = lambda do |msg|
              out = Fiddle::Pointer.malloc(32)
              sha256.call(msg, msg.bytesize, out)
              out.to_s(32)
            end
          end
        end

        def bind_sodium(fns, handle)
          bind = binder(handle)
          verify_detached = bind.call('crypto_sign_verify_detached')
          sign_detached = bind.call('crypto_sign_detached')
          seed_keypair = bind.call('crypto_sign_seed_keypair')
          return unless verify_detached

          # Sodium wins where it is installed (constant-time specialist).
          fns['ed25519_verify'] = lambda do |sig, msg, pk|
            verify_detached.call(sig, msg, msg.bytesize, pk).zero?
          end

          if sign_detached
            fns['ed25519_sign'] = lambda do |msg, seed|
              pk = fns['public_from_private'] ? fns['public_from_private'].call(seed) : nil
              raise UnavailableError, 'libsodium: cannot derive public key' if pk.nil?

              sigbuf = Fiddle::Pointer.malloc(64)
              siglen = Fiddle::Pointer.malloc(Fiddle::SIZEOF_SIZE_T)
              sk = seed + pk
              raise UnavailableError, 'crypto_sign_detached failed' unless sign_detached.call(sigbuf, siglen, msg, msg.bytesize, sk).zero?

              sigbuf.to_s(64)
            end
          end

          if seed_keypair
            fns['public_from_private'] = lambda do |seed|
              pkbuf = Fiddle::Pointer.malloc(32)
              skbuf = Fiddle::Pointer.malloc(64)
              raise UnavailableError, 'crypto_sign_seed_keypair failed' unless seed_keypair.call(pkbuf, skbuf, seed).zero?

              pkbuf.to_s(32)
            end
          end

          fns['generate_keypair'] = lambda do
            seed = Runes::Native.random_bytes(32)
            { seed: seed, pk: fns['public_from_private'].call(seed) }
          end
        end

        def bind_libc(fns)
          # macOS/BSD: arc4random_buf lives in the always-linked libSystem;
          # Linux: getrandom(2) via libc, looping over partial reads.
          default = Fiddle::Handle::DEFAULT
          arc4 = begin
            Fiddle::Function.new(default['arc4random_buf'], [Fiddle::TYPE_VOIDP, Fiddle::TYPE_SIZE_T], Fiddle::TYPE_VOID)
          rescue Fiddle::DLError
            nil
          end

          if arc4
            fns['random_bytes'] = lambda do |n|
              n = n.to_i
              raise UnavailableError, 'random_bytes: bad size' unless n.positive?

              buf = Fiddle::Pointer.malloc(n)
              arc4.call(buf, n)
              buf.to_s(n)
            end
            return
          end

          libc = open_first(['libc.so.6', 'libc.dylib'])
          getrandom = libc && begin
            Fiddle::Function.new(libc['getrandom'], [Fiddle::TYPE_VOIDP, Fiddle::TYPE_SIZE_T, Fiddle::TYPE_INT], Fiddle::TYPE_LONG)
          rescue Fiddle::DLError
            nil
          end
          return unless getrandom

          fns['random_bytes'] = lambda do |n|
            n = n.to_i
            raise UnavailableError, 'random_bytes: bad size' unless n.positive?

            buf = Fiddle::Pointer.malloc(n)
            filled = 0
            while filled < n
              got = getrandom.call(buf + filled, n - filled, 0)
              raise UnavailableError, 'getrandom failed' if got <= 0

              filled += got
            end
            buf.to_s(n)
          end
        end
      end

      EV_PKEY_ED = Runes::Native::EVP_PKEY_ED25519
      MANIFEST = Runes::Native::MANIFEST
    end
  end
end

Runes::Native::FiddleBackend.load!
