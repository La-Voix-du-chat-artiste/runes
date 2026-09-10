require 'wasmtime'
require 'securerandom'

module Runes
  module WASM
    # Manages a small pool of WASM VMs for executing untrusted tools.
    #
    # Backends
    # --------
    #   :real   — boots ruby.wasm in Wasmtime with WASI (stdin via buffer,
    #             stdout/stderr via pre-allocated buffers, optional workspace
    #             preopen, fuel metering, epoch wall-clock deadline).
    #   :mock   — in-memory stub. Used when the binary is missing, when the
    #             module fails to boot, or when backend: :mock is forced.
    #
    # Real-backend boot is *expensive* (~hundreds of ms for a 100MB
    # ruby.wasm) so we default to :auto and fall back to mock on any
    # failure, preserving the harness demo path. With backend: :real a
    # missing binary or failed boot is a hard error, never a silent mock.
    class VMManager
      # Boot of ruby.wasm alone consumes ~0.5–1B fuel (measured), so a
      # small script budget on top needs several billion. 5B gives ~5x
      # headroom over bare boot while still capping runaway scripts.
      DEFAULT_FUEL      = 5_000_000_000
      BUFFER_CAPACITY   = 512 * 1024  # 512 KiB stdout/stderr ring per VM.
      DEFAULT_POOL_SIZE = 1           # Real VMs are heavy; mock VMs are cheap.
      # Wall-clock limit per guest run. Fuel bounds compute, but WASI host
      # calls (e.g. poll_oneoff sleeps) do not consume fuel; the epoch
      # deadline bounds the whole run regardless (it interrupts at the
      # next guest checkpoint — WASI-blocked calls surface it late).
      DEFAULT_RUN_TIMEOUT_S = 30
      EPOCH_TICK_MS     = 100

      class VM
        attr_reader :backend, :boot_error

        # For the real backend we keep the (expensive) Engine, Module and
        # Linker cached but build a fresh Store + WasiConfig per run: WASI
        # stdin/stdout are bound at Store construction, so per-run code
        # injection requires a per-run Store.
        def initialize(backend:, engine: nil, module_: nil, linker: nil, wasm_path: nil, workspace: nil, boot_error: nil, run_timeout_s: nil)
          @backend = backend
          @engine = engine
          @module = module_
          @linker = linker
          @wasm_path = wasm_path
          @workspace = workspace
          @boot_error = boot_error
          @run_timeout_s = run_timeout_s
        end

        def mock?
          backend == :mock
        end

        def boot_error?
          !@boot_error.nil?
        end

        # Run a Ruby program. Returns a Hash { ok:, stdout:, stderr:, error:,
        # truncated:, mock: }. `fuel` bounds guest compute; `deadline_s`
        # (wall clock, default run_timeout_s from the manager; <= 0
        # disables) bounds the whole run via Wasmtime epoch interruption.
        def run(code, fuel: DEFAULT_FUEL, deadline_s: @run_timeout_s)
          return mock_run(code) if mock?

          out_buf = new_buffer
          err_buf = new_buffer
          begin
            wasi = Wasmtime::WasiConfig.new
            wasi.set_stdin_string(code.to_s)
            wasi.set_stdout_buffer(out_buf, BUFFER_CAPACITY)
            wasi.set_stderr_buffer(err_buf, BUFFER_CAPACITY)
            wasi.set_argv(['ruby'])
            attach_workspace(wasi)

            store = Wasmtime::Store.new(@engine, wasi_p1_config: wasi)
            # Fresh stores start at 0 fuel when metering is on, so
            # instantiation itself needs an allowance; reset after so the
            # script gets its full budget.
            store.set_fuel(fuel) if store.respond_to?(:set_fuel)
            set_epoch_deadline(store, deadline_s)
            instance = @linker.instantiate(store, @module)
            store.set_fuel(fuel) if store.respond_to?(:set_fuel)
            instance.invoke('_start')
            result(true, out_buf, err_buf, nil)
          rescue Wasmtime::Trap => e
            error = e.code == :interrupt ? "wall-clock timeout after #{deadline_s.to_i}s" : "trap: #{e.message}"
            result(false, out_buf, err_buf, error)
          rescue => e
            result(false, out_buf, err_buf, "#{e.class}: #{e.message}")
          end
        end

        private

        def result(ok, out_buf, err_buf, error)
          stdout = out_buf.strip.scrub
          stderr = err_buf.strip.scrub
          r = {
            ok: ok,
            stdout: stdout,
            stderr: stderr,
            error: error,
            # Truncation is silent otherwise; make it visible (W5).
            truncated: out_buf.bytesize >= BUFFER_CAPACITY || err_buf.bytesize >= BUFFER_CAPACITY
          }
          # Mock results must be distinguishable from real executions (W6).
          r[:mock] = true if mock?
          r
        end

        def set_epoch_deadline(store, deadline_s)
          return unless store.respond_to?(:set_epoch_deadline)
          return if deadline_s.nil? || deadline_s <= 0

          # The manager's engine ticks every EPOCH_TICK_MS; a delta of N
          # traps after ~N ticks. Add a little slack for coarse
          # checkpoints (WASI host calls only check on return).
          ticks = ((deadline_s * 1000.0) / EPOCH_TICK_MS).ceil
          store.set_epoch_deadline(ticks)
        rescue StandardError
          nil # epoch unavailable — fuel still bounds compute
        end

        def new_buffer
          String.new(capacity: BUFFER_CAPACITY) rescue (' ' * BUFFER_CAPACITY)
        end

        def attach_workspace(wasi)
          return unless @workspace && Dir.exist?(@workspace)

          # (host_path, guest_path, dir_perms, file_perms). Current
          # bindings take symbols: dir perms in [:read, :mutate, :all],
          # file perms in [:read, :write, :all].
          begin
            wasi.set_mapped_directory(@workspace, '/workspace', :all, :all)
          rescue TypeError, ArgumentError => e
            warn "[VMManager] workspace preopen fell back to octal perms (#{e.class}); binding mismatch worth checking"
            wasi.set_mapped_directory(@workspace, '/workspace', 0o755, 0o644) rescue nil
          end
        end

        def mock_run(code)
          { ok: true, stdout: "[mock] #{code.bytesize}B\n", stderr: '', error: nil,
            truncated: false, mock: true }
        end
      end

      def initialize(wasm_path, pool_size: DEFAULT_POOL_SIZE, backend: :auto, workspace: nil,
                     run_timeout_s: nil, settings: nil)
        @wasm_path = wasm_path
        @workspace = workspace # nil = NO preopen (fail-closed, S-W1)
        @settings = settings
        @run_timeout_s = run_timeout_s || default_run_timeout
        @pool = Queue.new
        @backend = resolve_backend(backend)
        @leased = {} # VM => true while checked out (double-release guard)
        @leased_mutex = Mutex.new
        @boot_error = nil
        pool_size.times { @pool << create_vm }
      end

      # Checking out re-marks the lease (release un-marks on return) so
      # the same VM can cycle acquire/release indefinitely while a
      # double release or a foreign VM stays rejected (W4).
      def acquire
        vm = @pool.pop
        @leased_mutex.synchronize { @leased[vm] = true }
        vm
      end

      # Returning a VM that is already in the pool (or was never leased by
      # this manager) corrupts the pool — two acquire callers would share
      # one VM. Ignore such releases loudly (W4); prefer `with_vm`.
      def release(vm)
        @leased_mutex.synchronize do
          unless @leased.delete(vm)
            warn '[VMManager] ignored invalid VM release (double release or foreign VM)'
            return
          end
        end
        @pool.push(vm)
      end

      # Structurally safe usage: acquires, yields, always releases.
      def with_vm
        vm = acquire
        begin
          yield vm
        ensure
          release(vm)
        end
      end

      def size = @pool.size
      attr_reader :backend, :run_timeout_s, :boot_error

      def boot_error?
        !@boot_error.nil?
      end

      private

      # B4-9: these two used to read the process ENV directly, so setting
      # RUNES_WASM / RUNES_WASM_TIMEOUT_S in config/.env (which every other
      # RUNES_* setting honours) was silently ignored.
      def env(key)
        @settings ? @settings.env(key) : ENV[key]
      end

      def default_run_timeout
        raw = env('RUNES_WASM_TIMEOUT_S')
        return DEFAULT_RUN_TIMEOUT_S if raw.nil? || raw.to_s.strip.empty?
        Float(raw)
      rescue ArgumentError
        DEFAULT_RUN_TIMEOUT_S
      end

      def resolve_backend(backend)
        return :mock if backend == :mock
        unless File.file?(@wasm_path)
          # An explicit :real request with a missing binary is a caller
          # bug — fail loud instead of silently running nothing (W2).
          raise ArgumentError, "backend: :real requested but wasm binary not found: #{@wasm_path}" if backend == :real
          warn "[VMManager] wasm binary missing (#{@wasm_path}); using mock backend"
          return :mock
        end

        # For :auto, require explicit opt-in via env var so demo runs stay
        # fast and deterministic. For :real, always attempt boot (and
        # explicitly surface errors via mock fallback with boot_error set).
        if backend == :auto
          return env('RUNES_WASM') == 'real' ? :real : :mock
        end
        :real
      end

      def create_vm
        vm = if @backend == :mock
               VM.new(backend: :mock)
             else
               begin
                 engine = Wasmtime::Engine.new(consume_fuel: true, epoch_interruption: true)
                 # One native ticker thread drives epoch advancement for every
                 # store built on this engine (W1 wall-clock deadline).
                 begin
                   engine.start_epoch_interval(EPOCH_TICK_MS)
                 rescue StandardError => e
                   warn "[VMManager] epoch ticker unavailable (#{e.class}: #{e.message}); wall-clock limit disabled"
                 end
                 mod = Wasmtime::Module.from_file(engine, @wasm_path)
                 linker = Wasmtime::Linker.new(engine)
                 Wasmtime::WASI::P1.add_to_linker_sync(linker)
                 VM.new(
                   backend: :real,
                   engine: engine,
                   module_: mod,
                   linker: linker,
                   wasm_path: @wasm_path,
                   workspace: @workspace,
                   run_timeout_s: @run_timeout_s
                 )
               rescue => e
                 warn "[VMManager] WASM boot failed (#{e.class}: #{e.message}); using mock backend."
                 @boot_error = e
                 VM.new(backend: :mock, boot_error: e)
               end
             end
        @leased_mutex.synchronize { @leased[vm] = true }
        vm
      end
    end
  end
end
