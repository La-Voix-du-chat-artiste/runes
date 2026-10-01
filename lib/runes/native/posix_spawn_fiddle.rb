# frozen_string_literal: true

# CRuby binder for Runes::ProcessSpawner via stdlib Fiddle — Tier C2
# (docs/spinel/spec-tier-c.md). Same C library entry points the Spinel FFI
# declares (Runes::Native::MANIFEST, lib: :c rows). All symbols live in the
# always-linked C library (libSystem on macOS, libc.so.6 on Linux), so the
# default process handle is enough.
require 'fiddle'

require_relative '../process_spawner'

module Runes
  module Native
    module PosixSpawnFiddle
      # POSIX_SPAWN_SETPGROUP (<spawn.h>, POSIX-standard flag value).
      POSIX_SPAWN_SETPGROUP = 0x02

      class << self
        def load!
          handle = Fiddle::Handle::DEFAULT
          fns = {}
          pipe_fn = fn(handle, 'pipe', %i[ptr], :int)
          close_fn = fn(handle, 'close', %i[int], :int)
          spawn_fn = fn(handle, 'posix_spawn', %i[ptr ptr ptr ptr ptr ptr], :int)
          waitpid_fn = fn(handle, 'waitpid', %i[long ptr int], :long)
          kill_fn = fn(handle, 'kill', %i[long int], :int)
          strerror_fn = begin
            fn(handle, 'strerror', %i[int], :ptr)
          rescue Fiddle::DLError
            nil
          end
          actions_init = fn(handle, 'posix_spawn_file_actions_init', %i[ptr], :int)
          actions_adddup2 = fn(handle, 'posix_spawn_file_actions_adddup2', %i[ptr int int], :int)
          actions_addchdir = begin
            fn(handle, 'posix_spawn_file_actions_addchdir_np', %i[ptr ptr], :int)
          rescue Fiddle::DLError
            begin
              fn(handle, 'posix_spawn_file_actions_addchdir', %i[ptr ptr], :int)
            rescue Fiddle::DLError
              nil
            end
          end
          attr_init = fn(handle, 'posix_spawnattr_init', %i[ptr], :int)
          attr_setpgroup = fn(handle, 'posix_spawnattr_setpgroup', %i[ptr long], :int)
          attr_setflags = fn(handle, 'posix_spawnattr_setflags', %i[ptr short], :int)
          return unless pipe_fn && spawn_fn && waitpid_fn && kill_fn && actions_init

          install_primitives(pipe_fn)
          install_spawn(fns, pipe_fn, close_fn, spawn_fn, actions_init, actions_adddup2,
                        actions_addchdir, attr_init, attr_setpgroup, attr_setflags, strerror_fn)
          install_kill_and_wait(fns, kill_fn, waitpid_fn)
          Runes::ProcessSpawner.install!(fns)
          fns
        end

        private

        def fn(handle, name, args, ret)
          Fiddle::Function.new(handle[name], args.map { |a| fiddle_type(a) }, fiddle_type(ret))
        rescue Fiddle::DLError
          nil
        end

        def fiddle_type(sym)
          case sym
          when :int then Fiddle::TYPE_INT
          when :short then Fiddle::TYPE_SHORT
          when :long then Fiddle::TYPE_LONG
          when :ptr then Fiddle::TYPE_VOIDP
          end
        end

        def install_primitives(pipe_fn)
          Runes::ProcessSpawner.primitives = {
            allocate: lambda { |size| Fiddle::Pointer.malloc(size) },
            write_bytes: lambda do |block, offset, bytes|
              block[offset, bytes.bytesize] = bytes
            end,
            address_of: lambda { |block| block.to_i },
            read_int32_pair: lambda do
              buf = Fiddle::Pointer.malloc(8)
              rc = pipe_fn.call(buf)
              raise Runes::ProcessSpawner::SpawnError, "pipe failed (rc=#{rc})" unless rc.zero?

              data = buf.to_s(8)
              fds = data.unpack('l<l<')
              [fds[0], fds[1]]
            end
          }
        end

        def install_spawn(fns, pipe_fn, close_fd, spawn_fn, actions_init, actions_adddup2,
                          actions_addchdir, attr_init, attr_setpgroup, attr_setflags, strerror_fn)
          fns['spawn'] = lambda do |argv, env, chdir|
            in_r, in_w = Runes::ProcessSpawner.pipe_pair!
            out_r, out_w = Runes::ProcessSpawner.pipe_pair!
            err_r, err_w = Runes::ProcessSpawner.pipe_pair!
            pid_buf = Fiddle::Pointer.malloc(8)

            begin
              actions = Fiddle::Pointer.malloc(512)
              actions[0, 512] = "\x00".b * 512 # malloc is NOT zeroed; spawn validates the struct
              actions_init.call(actions)
              add_action = lambda do |rc, what|
                raise Runes::ProcessSpawner::SpawnError, "file_actions #{what} failed (rc=#{rc})" unless rc.zero?
              end
              add_action.call(actions_adddup2.call(actions, in_r, 0), 'dup2 stdin')
              add_action.call(actions_adddup2.call(actions, out_w, 1), 'dup2 stdout')
              add_action.call(actions_adddup2.call(actions, err_w, 2), 'dup2 stderr')
              unless chdir.nil?
                raise Runes::ProcessSpawner::SpawnError, 'chdir unsupported on this platform' if actions_addchdir.nil?

                add_action.call(actions_addchdir.call(actions, Runes::ProcessSpawner.cstring(chdir)), 'chdir')
              end

              attr = Fiddle::Pointer.malloc(512)
              attr[0, 512] = "\x00".b * 512
              attr_init.call(attr)
              attr_setpgroup.call(attr, 0)
              attr_setflags.call(attr, POSIX_SPAWN_SETPGROUP)

              argv_block = Runes::ProcessSpawner.char_star_star(argv)
              env_block = Runes::ProcessSpawner.char_star_star(env.map { |k, v| "#{k}=#{v}" })
              path_addr = Runes::ProcessSpawner.cstring(argv.first)

              rc = spawn_fn.call(pid_buf, path_addr, actions, attr, argv_block, env_block)
              if rc.nonzero?
                message = strerror_fn ? strerror_fn.call(rc).to_s : "rc=#{rc}"
                raise Runes::ProcessSpawner::SpawnError, "posix_spawn failed: #{message} (#{argv.first})"
              end

              pid = pid_buf.to_s(8).unpack('l<l<')[0]
              # Parent ends: close the child's side of each pipe.
              close_fd.call(in_r)
              close_fd.call(out_w)
              close_fd.call(err_w)

              {
                pid: pid,
                stdin: IO.new(in_w, File::WRONLY),
                stdout: IO.new(out_r, File::RDONLY),
                stderr: IO.new(err_r, File::RDONLY)
              }
            rescue Exception
              [in_r, in_w, out_r, out_w, err_r, err_w].each { |fd| close_fd.call(fd) rescue nil }
              raise
            end
          end
        end

        def install_kill_and_wait(fns, kill_fn, waitpid_fn)
          fns['kill_tree'] = lambda do |pid|
            rc = kill_fn.call(-pid, 9) # the whole process group
            kill_fn.call(pid, 9) unless rc.zero?
            true
          rescue StandardError
            false
          end

          fns['wait'] = lambda do |pid|
            status_buf = Fiddle::Pointer.malloc(8)
            status_buf[0, 8] = "\x00".b * 8
            rc = waitpid_fn.call(pid, status_buf, 0)
            # CRuby auto-reaps children through its SIGCHLD handler, so a
            # posix_spawn'd child may already be gone (rc=-1, ECHILD). A
            # compiled kernel owns reaping and always sees a real status.
            return { unavailable: true } if rc <= 0

            Runes::ProcessSpawner.decode_wait_status(status_buf.to_s(4).unpack('l<l<')[0])
          end
        end
      end
    end
  end
end

Runes::Native::PosixSpawnFiddle.load!
