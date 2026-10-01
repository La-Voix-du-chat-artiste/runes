# frozen_string_literal: true

module Runes
  # Native crypto/random primitives over C libraries — the Tier B seam
  # (docs/spinel/spec-tier-b.md).
  #
  # Two binders supply the C functions, both normalizing to the same small
  # set of Ruby lambdas (see install!):
  #
  #   * Runes::Native::FiddleBackend   — CRuby stdlib Fiddle, exercised by
  #     the test suite against the real shared libraries (libcrypto today).
  #   * Runes::Native::SpinelFFI       — spinel compile-time ffi_func
  #     declarations (spin/kernel.rb), same C symbols, same conventions.
  #
  # Nothing here references Fiddle or ffi_lib directly, so this file is part
  # of the kernel subset. MANIFEST is the single source of truth for which C
  # functions a binder must cover; the suite audits both binders against it.
  module Native
    class UnavailableError < StandardError; end

    # c_name => { lib:, ret:, args: } — one row per C function. This is the
    # REQUIRED set every binder covers (libcrypto + libc). libsodium is an
    # OPTIONAL accelerator the Fiddle binder attaches when the library
    # happens to be installed — it is deliberately NOT in this manifest,
    # because Spinel links every declared ffi_lib unconditionally and a
    # missing optional library must not break the build.
    MANIFEST = {
      'EVP_PKEY_new_raw_public_key' => { lib: :crypto, ret: :ptr, args: %i[int ptr ptr size_t] },
      'EVP_PKEY_new_raw_private_key' => { lib: :crypto, ret: :ptr, args: %i[int ptr ptr size_t] },
      'EVP_PKEY_get_raw_public_key' => { lib: :crypto, ret: :int, args: %i[ptr ptr ptr] },
      'EVP_MD_CTX_new' => { lib: :crypto, ret: :ptr, args: [] },
      'EVP_MD_CTX_free' => { lib: :crypto, ret: :void, args: %i[ptr] },
      'EVP_DigestVerifyInit' => { lib: :crypto, ret: :int, args: %i[ptr ptr ptr ptr ptr] },
      'EVP_DigestVerify' => { lib: :crypto, ret: :int, args: %i[ptr ptr size_t ptr size_t] },
      'EVP_DigestSignInit' => { lib: :crypto, ret: :int, args: %i[ptr ptr ptr ptr ptr] },
      'EVP_DigestSign' => { lib: :crypto, ret: :int, args: %i[ptr ptr ptr ptr size_t] },
      'EVP_PKEY_free' => { lib: :crypto, ret: :void, args: %i[ptr] },
      'HMAC' => { lib: :crypto, ret: :ptr, args: %i[ptr ptr int ptr size_t ptr ptr] },
      'EVP_sha256' => { lib: :crypto, ret: :ptr, args: [] },
      'SHA256' => { lib: :crypto, ret: :ptr, args: %i[ptr size_t ptr] },
      'arc4random_buf' => { lib: :c, ret: :void, args: %i[ptr size_t] },
      'getrandom' => { lib: :c, ret: :long, args: %i[ptr size_t int] },
      'pipe' => { lib: :c, ret: :int, args: %i[ptr] },
      'close' => { lib: :c, ret: :int, args: %i[int] },
      'kill' => { lib: :c, ret: :int, args: %i[long int] },
      'waitpid' => { lib: :c, ret: :long, args: %i[long ptr int] },
      'posix_spawn' => { lib: :c, ret: :int, args: %i[ptr ptr ptr ptr ptr ptr] },
      'posix_spawn_file_actions_init' => { lib: :c, ret: :int, args: %i[ptr] },
      'posix_spawn_file_actions_adddup2' => { lib: :c, ret: :int, args: %i[ptr int int] },
      'posix_spawn_file_actions_addchdir_np' => { lib: :c, ret: :int, args: %i[ptr str] },
      'posix_spawn_file_actions_addchdir' => { lib: :c, ret: :int, args: %i[ptr str] },
      'posix_spawn_file_actions_destroy' => { lib: :c, ret: :int, args: %i[ptr] },
      'posix_spawnattr_init' => { lib: :c, ret: :int, args: %i[ptr] },
      'posix_spawnattr_setpgroup' => { lib: :c, ret: :int, args: %i[ptr long] },
      'posix_spawnattr_setflags' => { lib: :c, ret: :int, args: %i[ptr short] },
      'posix_spawnattr_destroy' => { lib: :c, ret: :int, args: %i[ptr] },
      'strerror' => { lib: :c, ret: :str, args: %i[int] }
    }.freeze

    # NID for EVP_PKEY_ED25519 (obj_mac.h); POSIX_SPAWN_SETPGROUP (<spawn.h>).
    EVP_PKEY_ED25519 = 1087
    POSIX_SPAWN_SETPGROUP = 0x02

    @fns = {}

    # binder-provided lambdas, normalized:
    #   ed25519_verify(sig, msg, pk32)            -> bool
    #   ed25519_sign(msg, seed32)                 -> sig64 (raises on failure)
    #   public_from_private(seed32)               -> pk32
    #   hmac_sha256(key, msg)                     -> dig32
    #   sha256_digest(msg)                        -> dig32
    #   random_bytes(n)                           -> String (raises UnavailableError)
    def self.install!(fns)
      @fns = fns
    end

    def self.installed?(name)
      !@fns[name].nil?
    end

    def self.unavailable!(what)
      raise UnavailableError, "Runes::Native: #{what} needs libsodium/libcrypto (set RUNES_SODIUM_LIB/RUNES_CRYPTO_LIB); no binder loaded it"
    end

    # --- Ed25519 ----------------------------------------------------------

    def self.ed25519_verify(signature, message, public_key)
      unless public_key.to_s.bytesize == 32 && signature.to_s.bytesize == 64
        return false
      end

      if installed?('ed25519_verify')
        @fns['ed25519_verify'].call(signature, message, public_key) ? true : false
      else
        unavailable!('Ed25519 verification')
      end
    rescue StandardError
      false
    end

    def self.ed25519_sign(message, seed)
      seed = seed.to_s
      raise UnavailableError, 'ed25519_sign: bad seed' unless seed.bytesize == 32

      if installed?('ed25519_sign')
        @fns['ed25519_sign'].call(message, seed)
      else
        unavailable!('Ed25519 signing')
      end
    end

    def self.public_from_private(seed)
      seed = seed.to_s
      raise UnavailableError, 'public_from_private: bad seed' unless seed.bytesize == 32

      if installed?('public_from_private')
        @fns['public_from_private'].call(seed)
      else
        unavailable!('Ed25519 public-key derivation')
      end
    end

    def self.generate_keypair
      if installed?('generate_keypair')
        @fns['generate_keypair'].call
      else
        seed = random_bytes(32)
        { seed: seed, pk: public_from_private(seed) }
      end
    end

    # --- MAC / digest -----------------------------------------------------

    def self.hmac_sha256(key, message)
      if installed?('hmac_sha256')
        @fns['hmac_sha256'].call(key, message)
      else
        unavailable!('HMAC-SHA256')
      end
    end

    def self.sha256_digest(message)
      if installed?('sha256_digest')
        @fns['sha256_digest'].call(message)
      else
        unavailable!('SHA256')
      end
    end

    # --- randomness -------------------------------------------------------

    def self.random_bytes(n)
      if installed?('random_bytes')
        @fns['random_bytes'].call(n)
      else
        unavailable!('CSPRNG')
      end
    end
  end
end
