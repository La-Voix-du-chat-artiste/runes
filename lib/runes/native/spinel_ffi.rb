# frozen_string_literal: true

# Spinel binder for Runes::Native — compile-time ffi_func declarations over
# the same C functions the Fiddle backend binds (docs/spinel/spec-tier-b.md,
# docs/spinel/spec-tier-a.md MANIFEST). This file is REQUIRED ONLY BY THE
# SPINEL KERNEL ENTRY (spin/kernel.rb); under CRuby it is never loaded. The
# suite syntax-checks it (`ruby -c`) and audits the declared functions
# against Runes::Native::MANIFEST so the two binders cannot drift.
#
# Out-parameters use IO::Buffer (see Spinel docs/FFI.md); C pointers are
# never stored, only destroyed in the same breath they were created.
require_relative '../native'
require_relative '../process_spawner'

module Runes
  module Native
    module LibCryptoFFI
      ffi_lib 'crypto'

      ffi_const :EVP_PKEY_ED25519, 1087

      ffi_func :EVP_PKEY_new_raw_public_key, [:int, :ptr, :ptr, :size_t], :ptr
      ffi_func :EVP_PKEY_new_raw_private_key, [:int, :ptr, :ptr, :size_t], :ptr
      ffi_func :EVP_PKEY_get_raw_public_key, [:ptr, :ptr, :ptr], :int
      ffi_func :EVP_MD_CTX_new, [], :ptr
      ffi_func :EVP_MD_CTX_free, [:ptr], :void
      ffi_func :EVP_DigestVerifyInit, [:ptr, :ptr, :ptr, :ptr, :ptr], :int
      ffi_func :EVP_DigestVerify, [:ptr, :ptr, :size_t, :ptr, :size_t], :int
      ffi_func :EVP_DigestSignInit, [:ptr, :ptr, :ptr, :ptr, :ptr], :int
      ffi_func :EVP_DigestSign, [:ptr, :ptr, :ptr, :ptr, :size_t], :int
      ffi_func :EVP_PKEY_free, [:ptr], :void
      ffi_func :HMAC, [:ptr, :ptr, :int, :ptr, :size_t, :ptr, :ptr], :ptr
      ffi_func :EVP_sha256, [], :ptr
      ffi_func :SHA256, [:ptr, :size_t, :ptr], :ptr
    end

    module LibSystemFFI
      ffi_lib 'c'

      ffi_func :arc4random_buf, [:ptr, :size_t], :void
      ffi_func :getrandom, [:ptr, :size_t, :int], :long

      # The whole posix_spawn dance lives in one ffi_source adapter so no
      # char** has to be assembled from Ruby: the argv/env strings arrive as
      # one NUL-separated blob, the pipes/dup2/chdir/pgroup happen in C.
      # Same syscalls as the Fiddle binder (Runes::Native::MANIFEST lib: :c
      # rows), string-audited by test/native_backend_test.rb.
      ffi_source <<~C
        #include <spawn.h>
        #include <string.h>
        #include <unistd.h>
        #include <errno.h>
        #include <stdlib.h>

        /* Returns the new pid, or -errno. fds_out receives the parent ends:
           [stdin_write, stdout_read, stderr_read]. */
        long runes_spawn(const char *path, const char *chdir,
                         int argc, const char *argv_blob,
                         int envc, const char *envp_blob,
                         int *fds_out) {
          char **argv = calloc((size_t)argc + 1, sizeof(char *));
          char **envp = calloc((size_t)envc + 1, sizeof(char *));
          for (int i = 0; i < argc; i++) { argv[i] = (char *)argv_blob; argv_blob += strlen(argv_blob) + 1; }
          for (int i = 0; i < envc; i++) { envp[i] = (char *)envp_blob; envp_blob += strlen(envp_blob) + 1; }

          int inpipe[2], outpipe[2], errpipe[2];
          if (pipe(inpipe) || pipe(outpipe) || pipe(errpipe)) { int e = errno; free(argv); free(envp); return -e; }

          posix_spawn_file_actions_t fa;
          posix_spawn_file_actions_init(&fa);
          posix_spawn_file_actions_adddup2(&fa, inpipe[0], 0);
          posix_spawn_file_actions_adddup2(&fa, outpipe[1], 1);
          posix_spawn_file_actions_adddup2(&fa, errpipe[1], 2);
          if (chdir && chdir[0]) {
        #if defined(__APPLE__)
            if (posix_spawn_file_actions_addchdir_np(&fa, chdir)) { int e = errno; free(argv); free(envp); return -e; }
        #else
            if (posix_spawn_file_actions_addchdir(&fa, chdir)) { int e = errno; free(argv); free(envp); return -e; }
        #endif
          }

          posix_spawnattr_t attr;
          posix_spawnattr_init(&attr);
          posix_spawnattr_setpgroup(&attr, 0);
          posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETPGROUP);

          pid_t pid = 0;
          int rc = posix_spawn(&pid, path, &fa, &attr, argv, envp);
          posix_spawn_file_actions_destroy(&fa);
          posix_spawnattr_destroy(&attr);
          free(argv); free(envp);
          if (rc) return -rc;

          close(inpipe[0]); close(outpipe[1]); close(errpipe[1]);
          fds_out[0] = inpipe[1]; fds_out[1] = outpipe[0]; fds_out[2] = errpipe[0];
          return (long)pid;
        }

        long runes_readfd(int fd, void *buf, long n) { return read(fd, buf, (size_t)n); }
        long runes_writefd(int fd, const void *buf, long n) { return write(fd, buf, (size_t)n); }
        int  runes_closefd(int fd) { return close(fd); }
        int  runes_killtree(long pid) {
          int rc = kill((pid_t)(-pid), 9);
          if (rc) rc = kill((pid_t)pid, 9);
          return rc;
        }
        long runes_wait(long pid, int *status) { return waitpid((pid_t)pid, status, 0); }
        /* CSPRNG in one entry point: arc4random_buf on macOS/BSD, getrandom
           loop elsewhere — so the Ruby glue needs no per-platform probing. */
        long runes_random(void *buf, long n) {
        #if defined(__APPLE__)
          arc4random_buf(buf, (size_t)n);
          return n;
        #else
          long filled = 0;
          while (filled < n) {
            long got = getrandom((char *)buf + filled, (size_t)(n - filled), 0);
            if (got <= 0) return -1;
            filled += got;
          }
          return filled;
        #endif
        }
      C

      ffi_func :runes_spawn, [:str, :str, :int, :ptr, :int, :ptr, :ptr], :long
      ffi_func :runes_readfd, [:int, :ptr, :long], :long
      ffi_func :runes_writefd, [:int, :ptr, :long], :long
      ffi_func :runes_closefd, [:int], :int
      ffi_func :runes_killtree, [:long], :int
      ffi_func :runes_wait, [:long, :ptr], :long
      ffi_func :runes_random, [:ptr, :long], :long
      ffi_func :strerror, [:int], :str
    end


    # Glue: normalized lambdas, same conventions as FiddleBackend.
    module SpinelGlue
      # An IO::Buffer holding the exact bytes of a string. Written
      # byte-by-byte through set_value: IO::Buffer.for (a read-only
      # wrapper over a String) is a CRuby API, not part of Spinel's
      # documented buffer surface.
      #
      # Multi-byte buffer access is ALSO composed from :U8 bytes on
      # purpose: C writes native little-endian through out-pointers, and
      # the width-suffixed accessors are not guaranteed to agree with
      # platform endianness across runtimes (observed big-endian reads on
      # spinel 2026.09.12). Byte-wise composition is exact everywhere.
      def self.read_u32le(buf, offset)
        buf.get_value(:U8, offset) |
          (buf.get_value(:U8, offset + 1) << 8) |
          (buf.get_value(:U8, offset + 2) << 16) |
          (buf.get_value(:U8, offset + 3) << 24)
      end

      def self.write_u32le(buf, offset, value)
        v = value.to_i
        buf.set_value(:U8, offset, v & 0xff)
        buf.set_value(:U8, offset + 1, (v >> 8) & 0xff)
        buf.set_value(:U8, offset + 2, (v >> 16) & 0xff)
        buf.set_value(:U8, offset + 3, (v >> 24) & 0xff)
      end

      def self.blob_buffer(bytes)
        text = bytes.to_s
        buf = IO::Buffer.new(text.bytesize)
        i = 0
        while i < text.bytesize
          buf.set_value(:U8, i, text.getbyte(i))
          i += 1
        end
        buf
      end

      class << self
        def install!
          fns = {}
          install_libcrypto(fns)
          install_libc(fns)
          Runes::Native.install!(fns)
          Runes::ProcessSpawner.install!(fns)
          fns
        end

        private

        def size_slot(value)
          slot = IO::Buffer.new(8)
          slot.set_value(:U64, 0, value)
          slot
        end

        def read_size(slot)
          slot.get_value(:U64, 0)
        end

        def install_libcrypto(fns)
          # direct constant receiver (no local alias — the analyzer resolves
          # ffi_func methods on the declaring module)

          fns['ed25519_verify'] = lambda do |sig, msg, pk|
            pkey = Runes::Native::LibCryptoFFI.EVP_PKEY_new_raw_public_key(Runes::Native::LibCryptoFFI::EVP_PKEY_ED25519, nil, blob_buffer(pk), pk.bytesize)
            next false if pkey == nil

            ctx = Runes::Native::LibCryptoFFI.EVP_MD_CTX_new
            begin
              next false unless Runes::Native::LibCryptoFFI.EVP_DigestVerifyInit(ctx, nil, nil, nil, pkey) == 1

              Runes::Native::LibCryptoFFI.EVP_DigestVerify(ctx, blob_buffer(sig), sig.bytesize, blob_buffer(msg), msg.bytesize) == 1
            ensure
              Runes::Native::LibCryptoFFI.EVP_MD_CTX_free(ctx)
              Runes::Native::LibCryptoFFI.EVP_PKEY_free(pkey)
            end
          end

          fns['ed25519_sign'] = lambda do |msg, seed|
            pkey = Runes::Native::LibCryptoFFI.EVP_PKEY_new_raw_private_key(Runes::Native::LibCryptoFFI::EVP_PKEY_ED25519, nil, blob_buffer(seed), seed.bytesize)
            raise Runes::Native::UnavailableError, 'EVP_PKEY_new_raw_private_key failed' if pkey == nil

            ctx = Runes::Native::LibCryptoFFI.EVP_MD_CTX_new
            begin
              unless Runes::Native::LibCryptoFFI.EVP_DigestSignInit(ctx, nil, nil, nil, pkey) == 1
                raise Runes::Native::UnavailableError, 'EVP_DigestSignInit failed'
              end

              sig = IO::Buffer.new(64)
              siglen = size_slot(64)
              unless Runes::Native::LibCryptoFFI.EVP_DigestSign(ctx, sig, siglen, blob_buffer(msg), msg.bytesize) == 1
                raise Runes::Native::UnavailableError, 'EVP_DigestSign failed'
              end

              sig.get_string(0, 64)
            rescue StandardError => e
              if ENV['SC_TRACE'] == '2'
                warn "ed25519_sign glue: #{e.class}: #{e.message} (sig.size=#{sig.size} msgbytes=#{msg.bytesize})"
              end
              raise
            ensure
              Runes::Native::LibCryptoFFI.EVP_MD_CTX_free(ctx)
              Runes::Native::LibCryptoFFI.EVP_PKEY_free(pkey)
            end
          end

          fns['public_from_private'] = lambda do |seed|
            pkey = Runes::Native::LibCryptoFFI.EVP_PKEY_new_raw_private_key(Runes::Native::LibCryptoFFI::EVP_PKEY_ED25519, nil, blob_buffer(seed), seed.bytesize)
            raise Runes::Native::UnavailableError, 'EVP_PKEY_new_raw_private_key failed' if pkey == nil

            begin
              out = IO::Buffer.new(32)
              outlen = size_slot(32)
              unless Runes::Native::LibCryptoFFI.EVP_PKEY_get_raw_public_key(pkey, out, outlen) == 1
                raise Runes::Native::UnavailableError, 'EVP_PKEY_get_raw_public_key failed'
              end

              out.get_string(0, 32)
            ensure
              Runes::Native::LibCryptoFFI.EVP_PKEY_free(pkey)
            end
          end

          fns['hmac_sha256'] = lambda do |key, msg|
            out = IO::Buffer.new(32)
            outlen = size_slot(32)
            result = Runes::Native::LibCryptoFFI.HMAC(Runes::Native::LibCryptoFFI.EVP_sha256, blob_buffer(key), key.bytesize, blob_buffer(msg), msg.bytesize, out, outlen)
            raise Runes::Native::UnavailableError, 'HMAC failed' if result == nil

            out.get_string(0, 32)
          end

          fns['sha256_digest'] = lambda do |msg|
            out = IO::Buffer.new(32)
            Runes::Native::LibCryptoFFI.SHA256(blob_buffer(msg), msg.bytesize, out)
            out.get_string(0, 32)
          end
        end

        def install_libc(fns)
          fns['random_bytes'] = lambda do |n|
            n = n.to_i
            raise Runes::Native::UnavailableError, 'random_bytes: bad size' unless n.positive?

            buf = IO::Buffer.new(n)
            got = Runes::Native::LibSystemFFI.runes_random(buf, n)
            raise Runes::Native::UnavailableError, 'runes_random failed' if got <= 0

            buf.get_string(0, n)
          end

          install_spawner(fns)
        end

        # ProcessSpawner over the ffi_source adapter. IO.new(fd) is not part
        # of the documented subset, so pipes are read/written/closed through
        # runes_* into IO::Buffer instead of IO objects.
        def install_spawner(fns)
          fns['spawn'] = lambda do |argv, env, chdir|
            fds = IO::Buffer.new(12)
            pid = Runes::Native::LibSystemFFI.runes_spawn(argv.first, chdir || '', argv.size,
                                                          Runes::Native::SpinelGlue.blob_buffer(argv.join("\x00") + "\x00"),
                                                          env.size,
                                                          Runes::Native::SpinelGlue.blob_buffer(env.map { |k, v| "#{k}=#{v}" }.join("\x00") + "\x00"),
                                                          fds)
            if pid < 0
              detail = begin
                Runes::Native::LibSystemFFI.strerror(-pid)
              rescue StandardError
                "rc=#{pid}"
              end
              raise Runes::ProcessSpawner::SpawnError, "runes_spawn failed: #{detail} (#{argv.first})"
            end

            {
              pid: pid,
              stdin: spawner_io(Runes::Native::SpinelGlue.read_u32le(fds, 0), :write),
              stdout: spawner_io(Runes::Native::SpinelGlue.read_u32le(fds, 4), :read),
              stderr: spawner_io(Runes::Native::SpinelGlue.read_u32le(fds, 8), :read)
            }
          end

          fns['kill_tree'] = lambda do |pid|
            Runes::Native::LibSystemFFI.runes_killtree(pid)
            true
          rescue StandardError
            false
          end

          fns['wait'] = lambda do |pid|
            status = IO::Buffer.new(8)
            rc = Runes::Native::LibSystemFFI.runes_wait(pid, status)
            return { unavailable: true } if rc <= 0

            Runes::ProcessSpawner.decode_wait_status(Runes::Native::SpinelGlue.read_u32le(status, 0))
          end
        end

        def spawner_io(fd, mode)
          SpawnerIO.new(fd, mode)
        end

        # Thin pipe wrapper over the ffi_source runes_* fd helpers. A real
        # class (not a Hash with singleton methods): Spinel restricts
        # singleton-method definition to user-class instances.
        class SpawnerIO
          def initialize(fd, mode)
            @fd = fd
            @mode = mode
            @buffer = IO::Buffer.new(65_536)
            @closed = false
          end

          def read(_n = nil)
            got = Runes::Native::LibSystemFFI.runes_readfd(@fd, @buffer, @buffer.size)
            got <= 0 ? String.new : @buffer.get_string(0, got)
          end

          def write(bytes)
            Runes::Native::LibSystemFFI.runes_writefd(@fd, Runes::Native::SpinelGlue.blob_buffer(bytes), bytes.bytesize)
          end

          def close
            unless @closed
              Runes::Native::LibSystemFFI.runes_closefd(@fd)
              @closed = true
            end
          end
        end

      end
    end
  end
end

Runes::Native::SpinelGlue.install!
