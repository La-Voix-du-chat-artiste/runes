# frozen_string_literal: true

require_relative 'compat'

module Runes
  # Process spawning without Open3, a shell, or fork — Tier C2
  # (docs/spinel/spec-tier-c.md). `posix_spawn` + file_actions gives the
  # compiled kernel exactly the containment `run_confined` has on CRuby:
  #
  #   * argv execution, never a shell string;
  #   * an EXACT environment (like Open3's unsetenv_others) — provider keys
  #     never leak to children;
  #   * closed/controllable stdin, separate stdout/stderr pipes;
  #   * the child in its OWN process group (posix_spawnattr SETPGROUP), so
  #     kill_tree reaches grandchildren — no orphans;
  #   * an optional chdir applied in the child, not the parent.
  #
  # The C functions are bound by the same two binders as Runes::Native
  # (fiddle_backend.rb under CRuby, spinel_ffi.rb under Spinel) and
  # installed here with `Runes::ProcessSpawner.install!(fns)`.
  module ProcessSpawner
    class SpawnError < StandardError; end

    @fns = {}

    def self.install!(fns)
      @fns = fns
    end

    def self.installed?(name)
      !@fns[name].nil?
    end

    def self.available?
      installed?('spawn')
    end

    # argv: Array<String> (no shell). env: Hash<String,String> or nil to
    # inherit nothing beyond what the caller passes — pass ENV.to_h when
    # inheritance is wanted. chdir: String or nil.
    #
    # Returns { pid:, stdin:, stdout:, stderr: } where the io values are
    # Ruby IO objects on the PARENT side of the pipes (caller closes).
    def self.spawn(argv, env: nil, chdir: nil)
      raise SpawnError, 'no process spawner bound' unless available?
      raise SpawnError, 'argv must not be empty' if argv.nil? || argv.empty?

      @fns['spawn'].call(argv, env || {}, chdir)
    end

    # SIGKILL the whole process group; falls back to the single pid.
    def self.kill_tree(pid)
      return unless installed?('kill_tree')

      @fns['kill_tree'].call(pid)
    end

    # Blocks until the child exits. Returns { exitstatus:, signaled: } — or
    # { unavailable: true } when the platform reaped the child before we
    # could read its status (CRuby's SIGCHLD auto-reaper does this; a
    # compiled kernel owns its children and always gets a status).
    def self.wait(pid)
      raise SpawnError, 'no process spawner bound' unless installed?('wait')

      @fns['wait'].call(pid)
    end

    # Pure wait(2) status decode — unit-tested with canned status words.
    def self.decode_wait_status(word)
      low = word & 0x7f
      { exitstatus: (word >> 8) & 0xff, signaled: low != 0, raw: word }
    end

    # --- shared helpers used by both binders --------------------------------

    # Pack ["a", "b"] into a char** block. The pointer array goes FIRST and
    # the strings AFTER it: macOS posix_spawn EFAULTs when string pointers
    # point backward into the same allocation (the wrapper copies a forward
    # range). The block MUST stay referenced for as long as C reads it.
    def self.char_star_star(strings)
      chunks = []
      total = 0
      strings.each do |s|
        chunk = Runes::Compat.binary(s) + "\x00"
        chunks << chunk
        total += chunk.bytesize
      end

      ptr_size = 8
      base = ptr_size * (strings.size + 1)
      block = allocate(base + total)
      offsets = []
      pos = base
      chunks.each do |chunk|
        offsets << pos
        write_bytes(block, pos, chunk)
        pos += chunk.bytesize
      end
      (strings.size + 1).times do |i|
        value = i < offsets.size ? address_of(block) + offsets[i] : 0
        write_bytes(block, i * ptr_size, Runes::Compat.byte_string([value & 0xff, (value >> 8) & 0xff, (value >> 16) & 0xff, (value >> 24) & 0xff, (value >> 32) & 0xff, (value >> 40) & 0xff, (value >> 48) & 0xff, (value >> 56) & 0xff]))
      end
      block
    end

    # A single NUL-terminated C string; returns its address (the block must
    # stay referenced for the duration of the call).
    def self.cstring(str)
      chunk = Runes::Compat.binary(str) + "\x00"
      block = allocate(chunk.bytesize)
      write_bytes(block, 0, chunk)
      address_of(block)
    end

    # Binder-provided raw memory primitives (Fiddle::Pointer or IO::Buffer).
    def self.primitives=(impl)
      @allocate = impl[:allocate]
      @write_bytes = impl[:write_bytes]
      @address_of = impl[:address_of]
      @read_int32_pair = impl[:read_int32_pair]
    end

    def self.allocate(size)
      @allocate ? @allocate.call(size) : raise(SpawnError, 'spawner primitives not installed')
    end

    def self.write_bytes(block, offset, bytes)
      @write_bytes.call(block, offset, bytes)
    end

    def self.address_of(block)
      @address_of.call(block)
    end

    # -> [read_fd, write_fd]
    def self.pipe_pair!
      pair = @read_int32_pair.call
      pair
    end
  end
end
