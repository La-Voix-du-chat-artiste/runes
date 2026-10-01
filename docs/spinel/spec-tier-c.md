# Spec — Tier C (blockers; solutions defined, C2 DELIVERED 2026-09-30)

Each entry: what blocks it, the chosen solution, and status.

## C1. Sockets — seam, not rewrite

**Blocks:** `transport/mqtt5.rb` (TCPSocket), `transport/mqtt311.rb` (`mqtt`
gem), `mqtt/broker.rb` (TCPServer), `core/llm_client.rb` (Net::HTTP).

**Solution (chosen):** the I/O shell stays CRuby behind the existing
injection seams (`Runes::Transport`, the LLM transport); the compiled kernel
ships its own socket layer later as a pure-Ruby-over-FFI adapter:
`socket/connect/read/write/shutdown/setsockopt` (~6 libc calls, same
manifest-audit pattern as Tier B) behind `Runes::Native`. Provider HTTP gets
a libcurl FFI adapter (`curl_easy_*`, ~8 calls) behind the same LLM
transport seam the suite already dups in tests.

**Status:** socket adapter NOT delivered. The pure `MQTT5::Codec` (all
packet build/parse) is the liftable part — it is the next small kernel
addition (audit + lint + self-check codec round-trip, verified by the
existing `mqtt5_codec_test`); the libc-socket binding is the last FFI
surface to land after it.

## C2. `Open3.popen3` — posix_spawn FFI (DELIVERED)

**Blocks:** `run_confined` containment and the workflow `cmd` rune.

**Solution (delivered):** `Runes::ProcessSpawner` over `posix_spawn`:

- `posix_spawn_file_actions_adddup2` wires the child's stdin/stdout/stderr
  to three pipes; `addchdir_np`/`addchdir` does the workspace chdir in the
  child; `posix_spawnattr_setpgroup(attr, 0)` + `POSIX_SPAWN_SETPGROUP`
  puts the child in its own group so `kill(-pid, 9)` reaches grandchildren.
- env arrives as a char** of `KEY=VALUE` strings — the exact environment,
  like `unsetenv_others`.
- CRuby binder: `native/posix_spawn_fiddle.rb` (Fiddle, verified here).
  Spinel binder: an `ffi_source` C adapter in `spinel_ffi.rb`
  (`runes_spawn`/`runes_readfd`/`runes_writefd`/`runes_closefd` /
  `runes_killtree`/`runes_wait`) — pointer-free on the Ruby side.
- **macOS landmines found and pinned by tests:** (1) `posix_spawn`
  EFAULTs when argv/envp string pointers point *backward* into the same
  allocation — the pointer array must come first; (2) Fiddle passes a Ruby
  String to `:ptr` WITHOUT a NUL terminator — build explicit C strings;
  (3) `Fiddle::Pointer.malloc` is uninitialized — zero action/attr structs.
- **CRuby verification boundary:** Ruby's SIGCHLD reaper consumes the exit
  status of FFI-spawned children (`waitpid` → ECHILD), so under CRuby
  `wait` reports `{unavailable: true}`; a compiled kernel owns reaping and
  gets real statuses. Status DECODE is a pure function pinned by unit
  vectors. Verified here: exact env, chdir, split pipes, kill_tree with no
  orphans, spawn errors.

## C3. Dynamic metaprogramming — runtime-guarded static bindings (DELIVERED 2026-09-30)

**Blocks:** `plugins/ruby.rb` (`method_missing`), the ruby_llm adapter
(dynamic `define_method`), `Transport.build`'s on-demand adapter requires,
and the engine's `define_singleton_method` loops
(`execution_manager.rb`, `config_manager.rb`, `cog_input_context.rb`).

**Solution (delivered):**

- `Runes::Runtime` seam: `dynamic_bindings?` (true on CRuby via
  `backends/cruby.rb`, false in compiled kernels), plus per-capability
  overrides — `bind_rune_type`/`bind_config_verb`/`bind_rune_verb` (dynamic
  binds; CRuby implements, compiled raises `StaticBindingError`),
  `require_cog`/`resolve_rune_class` (`use`), and `eval_workflow_source`.
- **Static literal bindings** for the seven verbs in `ExecutionManager`,
  `ConfigManager` and `CogInputContext` (literal `define_singleton_method`
  is the one form Spinel supports); the reduced kernel entry
  (`workflow_kernel.rb`) ships five compiled-safe runes — `cmd`, `ruby`,
  `call`, `map`, `repeat`. `chat`/`agent` stay CRuby (LLM/process shell).
- The `cmd` rune runs on the C2 spawner in compiled mode
  (`Runes::ProcessRunner::Native` behind the existing `command_runner`
  injection point).
- Engine blocked-construct sweep: `Struct(keyword_init:)` → plain classes,
  endless defs → normal defs, `Process.clock_gettime` → `Compat.monotonic`,
  `SecureRandom` → `Runes::Random`, `require "set"`/`"pathname"`/`"erb"` gone,
  `Pathname` → strings, `const_get` → three literal nested-constant lookups,
  `module_function` → `def self.`. Dynamic pieces moved to CRuby-only
  extension files: `Config.field` (workflow/config_field.rb), ruby-output
  method_missing delegation (plugins/ruby_delegation.rb), ERB `template`
  (workflow/templates.rb), `Telemetry::TransportSink`/`build_sink`
  (telemetry_sink.rb).
- **The one irreducible boundary:** evaluating a workflow *file* is
  `instance_eval(string)` — an AOT compiler cannot do it. Compiled kernels
  bake workflows in at build time; `Runes::Runtime.eval_workflow_source`
  raises a clear error there (and the CRuby parity entry overrides it, so
  the kernel self-check runs a real workflow end-to-end through the static
  bindings today).
- `Transport.build` on-demand adapter requires: moot for the kernel entry —
  it requires exactly the in-process hub and the manifest-selected FFI
  binders at compile time.

**Verification:** the full CRuby suite is green (681 runs, three seeds) —
the engine refactor changed no observable harness behavior; the kernel
self-check runs a real workflow (ruby + cmd-via-posix_spawn + map + repeat +
outputs) through the static bindings at 70 checks; the lint gate covers 47
kernel files with refined rules (literal `define_singleton_method(:cmd)` and
block-form `instance_eval(&proc)` allowed; computed names and string eval
blocked).

## C4. wasmtime real backend — deferred, with the surface listed

**Blocks:** the `wasmtime` gem (C extension).

**Solution (when needed):** FFI to the `wasmtime.h` C API:
`wasm_engine_new`, `wasm_engine_delete`, `wasmtime_module_new`,
`wasmtime_module_delete`, `wasmtime_linker_new`,
`wasmtime_linker_define_wasi`, `wasmtime_linker_instantiate`,
`wasmtime_store_new`, `wasmtime_store_delete`,
`wasmtime_store_context_*`, `wasmtime_context_set_fuel`,
`wasmtime_context_set_epoch_deadline`, `wasmtime_epoch_increase` (engine),
`wasmtime_call_*`/`_start` invoke, `wasmtime_error_message`/`delete` —
~20 functions. The mock backend stays the default everywhere; the real
backend only ever matters on the CRuby shell until an embedder asks.

## C5. Rails observatory — stays CRuby, by design

The observer already ingests through `Runes::Transport`; a compiled fleet
feeding a CRuby observer is the supported topology. No change.

## C6. Binary strings — discipline, not code

The MQTT5 codec's `.b`/`force_encoding` usage must become byte-array
discipline (integer-indexed access + `ffi_buffer` at the socket boundary)
when the codec lifts; JSON payloads are UTF-8 by contract so the facade
side is unaffected. Tracked in the M3 sweep notes.

## C7. `Process` APIs — closed

`Process.pid` (tmp names), `Process.clock_gettime` (ledgers/telemetry),
`Process.kill` (spawner) — all routed through facades (`Compat.monotonic`,
`Runes::Random`, `ProcessSpawner.kill_tree`).
