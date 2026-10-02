# Spec — Tier A kernel (delivered)

The contract for the Spinel-compilable kernel. The linter in
`test/spinel_subset_test.rb` enforces the BLOCKED rules on every file in
`KERNEL_FILES`; the VERIFY list is confirmed or revised on the first real
`spinel` build.

## Membership

```
lib/runes/compat.rb
lib/runes/json_facade.rb          (Runes::Json)
lib/runes/json_pure.rb            (Runes::JSONPure)
lib/runes/sha256_facade.rb        (Runes::SHA256 + pure SHA-256)
lib/runes/random_facade.rb        (Runes::Random + pure PRNG)
lib/runes/transport/topic_filter.rb
lib/runes/core/json_scan.rb
lib/runes/core/plan_parser.rb
lib/runes/security/command_policy.rb
lib/runes/security/nonce_cache.rb
lib/runes/request_ledger.rb
lib/runes/capabilities/guard.rb
lib/runes/guard_telemetry.rb      (pure core only)
lib/runes/kanban.rb
lib/runes/doc_store.rb
lib/runes/index.rb
lib/runes/transport/base.rb
lib/runes/transport/in_process.rb
```

Entry point: `spin/kernel.rb` (requires exactly the above, wires pure
backends, `selfcheck` mode). Nothing outside this list may be required,
directly or transitively, from the entry.

## Facades (injection points)

- `Runes::Json.parse(str, max_nesting: nil)` → Hash/Array/scalars; raises
  `Runes::Json::ParseError`. `Runes::Json.generate(obj)` → String.
  Backend set via `Runes::Json.backend = obj` (`obj.parse`, `obj.generate`).
  CRuby backend: `lib/runes/backends/cruby.rb` wraps stdlib `JSON`.
  Kernel backend: `Runes::JSONPure`.
- `Runes::SHA256.sha256_hex(str)` → 64-hex String. Default backend is the
  pure implementation; CRuby may install an OpenSSL-backed one.
- `Runes::Random.hex(n)` → 2n hex chars. **Ids and content addressing only.
  Never nonces, keys, or signatures** (Tier B `getrandom`). Default backend:
  pure xorshift seeded from `Time.now.to_f` + a process-unique counter;
  CRuby installs `SecureRandom`.
- `Runes::Compat`: `mkdir_p(dir)`, `basename(path)`, `utc_date` (UTC
  `YYYY-MM-DD`, epoch-civil arithmetic — deterministic across runtimes),
  `utc_iso8601(time, millis: true)` (CRuby: `iso8601(3)`; pure fallback:
  second precision + `.000Z`), `monotonic` (CRuby: CLOCK_MONOTONIC; pure
  fallback: wall clock — TTLs stay correct, only monotonicity weakens).

## BLOCKED constructs (linter-enforced)

Any of these in a kernel file fails the suite:

1. `eval`, `instance_eval`/`class_eval`/`module_eval` (string or no-arg
   receiver form), `method_missing`, `define_method`,
   `define_singleton_method`, `send`/`public_send`/`__send__`,
   `const_get`/`const_set`/`const_defined?` with non-literal names,
   `autoload`, `method(...)`.
2. `module_function` — modules expose `def self.` methods only.
3. `Struct.new` — plain classes with positional `initialize`.
4. Direct references to `::JSON`, `OpenSSL`, `Digest`, `SecureRandom`,
   `FileUtils`, `Date`, `Open3`, `Socket`/`TCPSocket`/`TCPServer`,
   `Net::HTTP`, `URI`, `Process`, `Bundler`, `Set`.
5. `require`/`require_relative` of non-kernel files (the linter checks the
   entry's transitive closure by listing).
6. Endless method defs (`def x = …`).

## VERIFY list — RESOLVED by the first native build (2026-10-01)

Spinel 2026.09.12+3496, macOS arm64. What the VERIFY items turned out to
be, and the shape each fix took (all are in the code with comments):

| Item | Finding | Resolution |
|---|---|---|
| `define_singleton_method` (even literal) | **Not supported at all** — "define the method in the class body instead" | Static bindings became class-body methods on `ExecutionContext`/`ConfigContext`/`CogInputContext` with registry dispatch (`Runes::Plugin[verb]`) — no per-instance tables anywhere in compiled code; dynamic binds stay behind `Runes::Runtime` (CRuby-only file) |
| `Object#extend` | Not supported | `WorkflowParamAccessors` is `include`d in `Config`'s class body |
| `instance_eval(string)` | Only block form supported | `Runes::Runtime.eval_workflow_source` seam (CRuby impl `instance_eval`s; compiled kernels raise — workflows are baked in at build time) |
| `ENV` as a value | Compile-time receiver only | `Compat.env_snapshot` builds a Hash via `ENV.each_pair` |
| `Object#object_id`, `Process` | poly/absent | Seeds and clocks via `Compat` (Time arithmetic, no pid) |
| `case/when` class narrowing on poly | `elsif` chains don't narrow; helper params inferred from call sites DO | `WorkflowParams.from` restructured into `from_hash` helpers |
| `String#<<` / out-param mutation | **The analyzer sometimes passes the accumulator `const char*` BY VALUE** (whole-program shape-dependent): every `<<` silently dropped (found via `JSONPure.generate` returning `""`) | Emitters rewritten in pure value style (`out = out + piece`, return the accumulator) — correct in both shapes |
| `IO::Buffer` feature detection | Whole-program builds **miss uses inside required-file lambdas/singletons** → every `IO::Buffer.new` became `raise NameError("uninitialized constant Buffer")` | **Fixed upstream** (matz/spinel 3a5fccc73, via [#6740](https://github.com/matz/spinel/issues/6740)): the implicit `io/buffer` require now gets a whole-program check. The `IO_BUFFER_PROBE` workaround is deleted and the kernel self-checks 70/70 without it on 2026.09.12+4479 |
| `IO::Buffer.get/set_value(:U64/:S32)` | Reads came back byte-swapped vs C's native little-endian out-params (siglen decoded as 0x4000000000000000). **Not a Spinel divergence on re-test**: `IO::Buffer.new` is big-endian by default under CRuby too, and Spinel matches CRuby exactly — this was OUR assumption that `:U64` meant native order (the CRuby path read via Fiddle, which is native). Filed-reports note: withdrawn as a compiler report; kept here as the IO::Buffer default-endianness trap | All multi-byte buffer access composed from `:U8` bytes (`SpinelGlue.read_u32le/write_u32le`); fixed-size reads (Ed25519 sig = 64B, HMAC = 32B) read fixed sizes |
| `IO::Buffer.for` | Not part of Spinel's documented buffer surface | `SpinelGlue.blob_buffer` builds byte-by-byte |
| `send(name)` with a runtime Symbol | Literal `send(:name)` only | Static call lists; per-check `warn` tracing instead of dispatch tables |
| Module-state predicates (`installed?`) | **Constant-folded at analysis time** (ivar still nil when the analyzer evaluates) | Self-check probes by doing (first real spawn) instead of asking |
| `Runes::Cog = Rune` alias | The analyzer does not see through the alias (`Cog::Config` "defined nowhere", cascading `unsupported call`) | Compiled code references `Runes::Rune::*` only; the alias remains for CRuby API compat |
| `require` order vs file-scope `install!` | CRuby masked it; load order is real at runtime | `spinel_ffi.rb` now requires `process_spawner` before its file-scope `install!` |
| `pack`/`unpack`/`format`/`rjust` | Runtime landmines in whole-program builds (`pack('C')` → the `Buffer` NameError above) | Removed entirely from kernel code — `Compat.byte_string/hex_encode/hex_decode/base64_encode/base64_decode/pad_left` (pure, parity-pinned) |
| `String#bytesize/getbyte/chr`, `respond_to?`, `match?`, `Dir.glob`, `File#flock/realpath`, keyword args, blocks, threads | **Supported as hoped** | No change needed |

Post-fix state: `build/runes-kernel selfcheck` passes 70/70 natively; the
CRuby suite is unchanged-green.

**Filed upstream (2026-10-01, matz/spinel):**
[#6740](https://github.com/matz/spinel/issues/6740) — the required-file
`IO::Buffer` linking gap, with a two-file minimal repro (verified on
2026.09.12+3496: same expression works on the main path, raises
`NameError` from a required file). [#6741](https://github.com/matz/spinel/issues/6741)
— the by-value accumulator and the analysis-time ivar folding as
shape-dependent observations (no current minimal repro; both fixed on our
side). The `:U64` row above was re-tested and withdrawn as a compiler
report: Spinel matches CRuby there — see its entry.

## Memory model audit (for the no-GVL runtime)

Shared kernel state and its status:

- `NonceCache`, `RequestLedger`: correct under true parallelism (all state
  under one `Mutex`). **Sound.**
- `InProcess::Hub`: `@mutex` guards subscriptions/retained/cursors;
  delivery happens outside the lock (handler may re-publish — no deadlock).
  **Sound.**
- `GuardTelemetry` window counters (`@window_count` etc.): benign race —
  worst case is a slightly off rate cap. Accepted, documented.
- `Capabilities::Guard`: read-mostly after construction; `@deny_logged`
  dedup hash may double-log a line under a race. Benign. Accepted.
- `DocStore`: write-then-rename under unique tmp names; concurrent identical
  `put` may both write the tmp then rename — last rename wins, content is
  identical (content-addressed). **Sound.**

## Behavioral contracts (unchanged, pinned by the existing suite)

- Guard: default-deny; unreadable policy ⇒ *nothing* granted (fail closed);
  manifest fragments additive-only for builtins.
- CommandPolicy verdict categories and messages unchanged
  (`:empty/:metacharacters/:path/:dangerous/:allowlist`).
- Kanban: `render(parse(text))` round-trips; `validate` matches the external
  `validate_mermaid.rb` contract; `update_file` holds `flock` for the whole
  read-modify-write.
- RequestLedger: first claim inside TTL wins; `complete` stores a ≤512-byte
  outcome; eviction oldest-first.
- TopicFilter: MQTT 3.1.1 §4.7 semantics incl. `#`-final-only, `+` empty
  level, `$`-prefixed topics immune to leading wildcards.
- InProcess: retained replay at subscribe; shared-group delivery is
  exclusive and round-robin; delivery outside the lock.

## Delivered-state deltas (documented behavior changes)

1. `Kanban` `created_at` default is now **UTC** (`Compat.utc_date`) where it
   was local (`Date.today`). One-day difference only between local midnight
   and 00:00 UTC; no test or documented consumer depends on the local date.
2. `DocStore` tmp-file uniqueness no longer uses `Process.pid`; uses the
   Random facade. Same atomic-rename safety.
3. `GuardTelemetry` transport sink lives in
   `lib/runes/guard_telemetry_sink.rb` (harness-only). Kernel users inject a
   callable via `Runes::GuardTelemetry.sink =`.
