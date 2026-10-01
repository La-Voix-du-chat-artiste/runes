# PRD — Runes kernel under Spinel

> Product-requirements document for compiling the Runes "kernel" (the
> CPU-bound, security-relevant pure libraries) with
> [spinel](https://github.com/matz/spinel), Matz's Ruby AOT compiler.
> Companion: `docs/spinel-compatibility.md` (the analysis) and
> `docs/spinel/spec-tier-{a,b,c}.md` (the contracts).

## Problem

Runes agents are long-running local processes booting a full CRuby with a
Gemfile of native extensions (`mqtt`, `sqlite3`, wasmtime optional). For a
"local-first fleet" story this is heavy: slow boot, large RSS, and the moat
(auditable, embeddable, fail-closed verification) is diluted when the
verification kernel cannot ship as a small standalone binary.

Spinel compiles a Ruby subset to standalone native executables (no CRuby at
runtime, ~8.5x over YJIT on compute-bound code). The question is not "can we
compile bin/runes" — it is "**what is the largest useful subset we can
compile, and what does compiling it buy us?**"

## Goal

Ship a **Runes kernel** that:

1. compiles with `spinel` to a standalone native binary,
2. behaves identically under CRuby today (full test suite green, zero
   behavioral regressions),
3. is guarded so it *stays* compilable (CI lint, no drift back into
   unsupported constructs),
4. runs its own hermetic self-check on both backends
   (`spin/kernel.rb selfcheck` under CRuby now, under Spinel when a binary is
   present),
5. leaves the networked I/O shell behind the existing injection seams
   (`Runes::Transport`, LLM transport, `CommandRunner`) — unchanged
   architecture, not a fork.

## Non-goals

- Compiling the MQTT adapters, embedded broker, LLM router (Net::HTTP), or
  the Rails observatory in this PRD's horizon. Spec'd as Tier C.
- Replacing CRuby for the developer workflow (tests, demos, TUI) — CRuby
  remains the primary runtime.
- Crypto agility: Ed25519/HMAC stay exactly where they are (`openssl` /
  future FFI). The kernel ships pure-Ruby SHA-256 and a PRNG **for ids and
  content addressing only**, never for nonces or signatures.
- Benchmark heroics: we publish the kernel microbench delta only after a real
  Spinel build exists.

## Personas / user stories

- **Fleet operator:** "I want a 5 MB agent binary that boots in milliseconds
  and still enforces the capability guard, dedupes requests, and validates
  missions — with the broker/LLM side supplied by my existing adapters."
- **Embedder (framework author):** "I want `Guard` + `CommandPolicy` +
  `TopicFilter` + the ledger as one native library I can link, without
  dragging CRuby along."
- **Runes maintainer:** "I want a CI gate that fails the moment someone adds
  `method_missing` or a `require 'json'` to a kernel file."

## Milestones

### M1 — Tier A kernel (DELIVERED 2026-09-30, this batch)

- Facades: `Runes::Json`, `Runes::SHA256`, `Runes::Random`, `Runes::Compat`
  (stdlib decoupling points).
- Pure foundations (delivered ahead of the original Tier B slot because the
  self-check needs them, and pure beats FFI for hermeticity):
  `Runes::JSONPure` strict parser/generator; pure SHA-256; pure PRNG.
- Subset refactor of the kernel files: `def self.` modules instead of
  `module_function`; plain classes instead of `keyword_init` Structs; no
  `filter_map`/`each_with_object`/endless defs; `Regexp.union` removed;
  `Date`/`FileUtils`/`File.basename`/`Process.*` routed through `Compat`.
- `GuardTelemetry` split: pure core (in kernel) vs transport sink (harness).
- `spin/kernel.rb` self-check + `scripts/spinel_build.rb` (compiles with
  `spinel` when on PATH, CRuby parity mode otherwise).
- `test/spinel_subset_test.rb`: static subset linter + JSON/SHA-256 parity
  tests.

Exit criteria: full suite green; linter green; self-check passes under CRuby
with pure backends; `spinel` build passes where a binary exists (else
explicitly skipped, never silent).

### M2 — Tier B FFI backends (DELIVERED 2026-09-30)

- `Runes::Native` primitive layer with a manifest-audited pair of binders:
  `native/fiddle_backend.rb` (CRuby stdlib Fiddle — drives the real
  libcrypto, verified against OpenSSL both directions) and
  `native/spinel_ffi.rb` (Spinel `ffi_func` DSL, parse-checked and
  manifest-audited).
- `Runes::Security::CryptoBackend` seam: OpenSSL backend (CRuby, unchanged
  behavior) / Native backend (FFI). Ed25519 sign/verify/derive, HMAC-SHA256.
- `Runes::Random.bytes` CSPRNG path (arc4random/getrandom FFI); PRNGPure
  demoted to ids-only as documented.
- Pure `Runes::Security::Ed25519Der` PKCS#8/SPKI codec — byte-identical to
  OpenSSL output; fingerprints of existing `kid`s unchanged.
- Settings store seam: SQLite (CRuby, unchanged) / JSONL (pure, atomic).
  Full Settings stays out of the compiled kernel (LLMClient coupling, M4).
- Exit criteria met: suite green (675 runs, three seeds), RFC 4231 vectors,
  kernel self-check at 61 checks under Fiddle-bound libcrypto.

### M3 — Workflow engine (Tier A′/C3) (DELIVERED 2026-09-30)

- `Runes::Runtime` capability seam; static literal bindings for the verbs
  in the engine; dynamic conveniences (`Config.field`, ruby method_missing
  delegation, ERB templates, `use`) moved to CRuby-only extension files.
- Reduced kernel engine entry (`workflow_kernel.rb`): cmd, ruby, call, map,
  repeat; chat/agent stay CRuby. The `cmd` rune runs on the C2 spawner via
  `Runes::ProcessRunner::Native`.
- Irreducible boundary documented: workflow *file* evaluation is
  `instance_eval(string)` — CRuby-only; compiled kernels bake workflows in
  at build time.
- Exit criteria met: suite green (681 runs, three seeds), kernel
  self-check runs a real workflow through static bindings (70 checks).

### M4 — Network shell decision

- Either an FFI sockets layer (libc sockets for MQTT5 + libcurl for provider
  HTTP) or the recommended shape: compiled kernel + thin CRuby I/O shell
  behind `Runes::Transport` / LLM transport injectors (already the test
  architecture).

### M5 — Out of scope (recorded)

- `runes_observer/` Rails app; `wasmtime` real backend (FFI to `wasmtime.h`
  possible, large surface); TUI termios.

## Success metrics — MEASURED 2026-10-01 (spinel 2026.09.12+3496, macOS arm64)

1. **Correctness:** the existing suite passes unmodified — **681 runs /
   4393 assertions / 0 failures**, two fixed seeds (16007-class, 4242).
2. **Drift-proofing:** the subset linter runs in the normal suite; 47
   kernel files gated.
3. **Hermeticity:** `spin/kernel.rb selfcheck` passes with the pure
   backends — **VERIFIED NATIVE: `KERNEL SELFCHECK OK (70 checks)`** on the
   compiled binary.
4. **Performance:**
   - Binary size: **1.8 MB** standalone (`build/runes-kernel`, includes
     libcrypto/libc FFI and the ffi_source spawner adapter).
   - Cold run: **~40–50 ms wall** for process start + the full 70-check
     self-check (which spawns processes, signs/verifies Ed25519, runs a
     workflow). The CRuby parity entry does the same in ~150–310 ms.
   - The 70 checks exercise the kernel's own hot paths; microbenchmarks
     vs CRuby+YJIT per phase remain open (the harness comparison harness
     lives in `spinel/benchmark` style; not blocking).

## First native build — compiler findings

The first real compile (2026-10-01) surfaced eight genuine Spinel quirks,
each worked around in the kernel with a comment and catalogued in
`docs/spinel/spec-tier-a.md` §VERIFY: by-value accumulator miscompile
(string-building rewritten in value style), IO::Buffer feature-detection
gap (main-path probe), `:U64` big-endian reads (byte-wise composition),
`define_singleton_method`/`extend` unsupported (class-body registry
dispatch), `send(name)`/ivar-predicate const-folding (probe by doing),
`Cog = Rune` alias blindness, `pack/unpack/format` landmines (pure Compat
replacements), and require-order vs file-scope `install!`.

## Risks

| Risk | Mitigation |
|---|---|
| Spinel subset drifts (a **VERIFY** method turns out unsupported) | VERIFY list in spec A is small and localized; first real build revises it; CRuby parity is unaffected |
| Thread memory model (no GVL) exposes benign-race state | Audit list in spec A §Memory model; Mutex is supported; fixes are mechanical |
| Pure JSON/SHA-256 slower than stdlib | Acceptable for the kernel's sizes (≤1 MiB payloads); Tier B FFI restores speed where it matters |
| PRNG misuse for secrets | Documented loudly on `Runes::Random`: ids/content-addressing only; nonces/signatures stay Tier B |
| Dual-runtime divergence (kernel pure backends vs CRuby stdlib) | Parity tests in the suite pin both to the same observable behavior |

## Open questions

1. Spin package layout: ship the kernel as a `spin`-installable package for
   embedders, or keep the source-tree entry (`spin/kernel.rb`) only? Decide
   after the first real `spinel` build.
2. Does `lib/runes.rb` keep loading the pure foundations under CRuby, or
   should CRuby prefer stdlib JSON (current choice: stdlib under CRuby, pure
   under the spin kernel — revisit if parity bugs ever appear)?
