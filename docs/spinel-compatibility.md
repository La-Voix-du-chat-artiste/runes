# Spinel compatibility — what compiles, what does not, and why

> Status: **VERIFIED ON A REAL SPINEL BUILD (2026-10-01, spinel
> 2026.09.12+3496, macOS arm64).** The kernel compiles to a 1.8 MB
> standalone binary that passes all 70 self-checks natively — pure JSON,
> the guard, kanban, the in-process transport, real libcrypto Ed25519 +
> HMAC through the FFI, posix_spawn process containment, the workflow
> engine over static bindings, and the JSONL settings store. The CRuby
> harness remains fully green (681 runs, 0 failures, two seeds). See
> `docs/spinel/PRD.md` for metrics and `docs/spinel/spec-tier-a.md` §First
> native build for the compiler findings this build surfaced.

[Spinel](https://github.com/matz/spinel) is Matz's Ruby AOT compiler: a
whole-program, type-inferred Ruby subset → C → standalone native binary. No
CRuby at runtime. No sockets, no `eval`, no `method_missing`, no dynamic
`define_method`, a deliberately small stdlib (JSON/OpenSSL/Digest are absent;
FFI covers C libraries). Benchmarks claim ~8.5x over Ruby 4.0 +YJIT on
compute-bound code.

## The shape of the answer

The harness is already seam-shaped for this cut: `transport:` injection on
the dispatcher, the LLM transport injector, the injectable `CommandRunner`.
So the strategy is not "compile bin/runes" — it is **compile the kernel**
(the CPU-bound, security-relevant pure libraries), and keep the I/O shell
(sockets, process pipes, HTTP) behind those same seams, either as FFI or as
the existing CRuby adapters.

```
┌──────────────────────────  spinel kernel (Tier A)  ─────────────────────────┐
│ topic_filter · json_scan · plan_parser · command_policy · nonce_cache        │
│ request_ledger · guard · guard_telemetry(core) · kanban · doc_store · index  │
│ transport/base · transport/in_process                                        │
│ compat · JSON facade (+ pure parser) · Digest facade (+ pure SHA-256)        │
│ Random facade (+ pure PRNG)                                                  │
└──────────────────────────────────────────────────────────────────────────────┘
        ▲ requires facades only            ▲ outer shell keeps stdlib/FFI (Tier B/C)
```

## Tier map

### Tier A — in the kernel today (pure subset)

| Module | Notes |
|---|---|
| `Runes::Transport::TopicFilter` | pure regex/string matching |
| `Runes::Core::JsonScan` | string-aware brace scanner; JSON via facade |
| `Runes::Core::PlanParser` | strict-JSON + legacy text plans; JSON via facade |
| `Runes::Security::CommandPolicy` | metachar/path/allowlist checks; `File.basename` → `Compat` |
| `Runes::Security::NonceCache` | bounded mutex'd nonce set |
| `Runes::RequestLedger` | claim/outcome dedupe ledger |
| `Runes::Capabilities::Guard` | policy merge + deny; JSON via facade |
| `Runes::GuardTelemetry` (core) | rate-capped refusal record; sink injection; transport sink split out |
| `Runes::Kanban` | `.mmd` render/parse/validate; `Date` → `Compat.utc_date` |
| `Runes::DocStore` | content addressing; SHA-256 via facade; `mkdir_p` → `Compat` |
| `Runes::Index` | `#E-001` code index over files |
| `Runes::Transport::Base` / `InProcess` | message hub with shared-group delivery; threads/Mutex only |

Foundation delivered with Tier A (needed by the kernel self-check, listed as
Tier B in the PRD but implemented pure-Ruby now because the kernel must run
hermetic everywhere):

- `Runes::Json` facade + `Runes::JSONPure` strict recursive-descent parser /
  generator (parity-tested against stdlib JSON).
- `Runes::SHA256` facade + pure-Ruby SHA-256 (parity-tested against OpenSSL).
- `Runes::Random` facade + pure-Ruby PRNG (xorshift; **ids only, never
  nonces** — envelope/RPC nonces remain Tier B FFI to `getrandom`).
- `Runes::Compat`: `mkdir_p`, `basename`, `utc_date`, `utc_iso8601`,
  `monotonic` — portable implementations with no stdlib deps beyond `File`,
  `Dir`, `Time`.

### Tier B — DELIVERED 2026-09-30 (FFI backends, verified under CRuby)

| Need | Delivered as |
|---|---|
| Ed25519 sign/verify (`envelope.rb`, `identity.rb`) | `CryptoBackend` seam + `CryptoBackends::Native` over `Runes::Native` FFI (libsodium preferred, libcrypto fallback — libcrypto verified here) |
| HMAC-SHA256 freshness (`rpc_auth.rb`) | `CryptoBackend.hmac_sha256` → one-shot `HMAC(EVP_sha256(),…)`; RFC 4231 vectors pinned |
| Cryptographic randomness | `Runes::Random.bytes` → `arc4random_buf`/`getrandom` FFI (CSPRNG); `PRNGPure` stays ids-only |
| PEM/DER without OpenSSL | pure `Runes::Security::Ed25519Der` (PKCS#8/SPKI), byte-identical to OpenSSL output |
| Preferences DB (`settings.rb`) | `SettingsStore` seam: SQLite (CRuby, unchanged) / JSONL (pure, atomic) — the spec's JSONL pick |
| Time precision (B4) | **deferred** — wall-clock TTL fallback is correct; `clock_gettime` FFI when a compiled kernel needs it |

Verification: the Fiddle binder drives the real libcrypto through the same C
functions/signatures the Spinel FFI declarations bind — cross-checked
against OpenSSL both directions in `test/native_backend_test.rb`; the Spinel
FFI file is manifest-audited and syntax-checked; the kernel self-check (61
checks incl. envelope replay + RFC 4231) passes under
`spin/kernel_cruby.rb`.

### Tier C — solutions defined in `docs/spinel/spec-tier-c.md`; C2 DELIVERED

1. **Sockets** — `transport/mqtt5.rb` (TCPSocket), `transport/mqtt311.rb`
   (`mqtt` gem), `mqtt/broker.rb` (TCPServer), `core/llm_client.rb`
   (Net::HTTP). Spinel's I/O is `File` + `system()` + backtick. The MQTT 5
   *codec* is pure byte work and lifts into the kernel with the M3 sweep;
   the socket layers get a libc-socket FFI adapter (M4) or stay on CRuby
   behind `Runes::Transport` — the recommended topology until an edge-box
   customer needs native sockets.
2. **`Open3.popen3` — DELIVERED (C2).** `Runes::ProcessSpawner` over
   `posix_spawn` reproduces every `run_confined` property without a shell:
   dup2'd pipe triple, child-side chdir, SETPGROUP + `kill(-pid)` for
   orphan-free kills, exact `KEY=VALUE` env. Fiddle binder verified on
   macOS — including three real landmines now pinned by tests (macOS
   `posix_spawn` EFAULTs on backward argv pointers; Fiddle passes String→
   `:ptr` without a NUL; `Pointer.malloc` is uninitialized). Spinel side:
   an `ffi_source` C adapter, string-audited against the manifest.
   Documented CRuby boundary: Ruby's SIGCHLD reaper owns exit statuses
   under CRuby (`wait` → `{unavailable: true}`); a compiled kernel reads
   real statuses (decode pinned by pure unit vectors).
3. **Metaprogramming — DELIVERED (C3, 2026-09-30).** `Runes::Runtime`
   seam with static literal bindings for the verbs; the reduced kernel
   engine (`workflow_kernel.rb`) ships cmd/ruby/call/map/repeat with cmd on
   the C2 spawner; `Config.field`, ruby method_missing delegation, ERB
   templates and `use` moved to CRuby-only extension files. The one
   irreducible boundary: evaluating a workflow *file* is string-eval —
   compiled kernels bake workflows in at build time.
4. **wasmtime** — deferred; ~20-function `wasmtime.h` surface listed in the
   spec. Mock backend stays the default everywhere.
5. **Rails observatory** — stays CRuby by design (a compiled fleet feeding
   a CRuby observer is the supported topology).
6. **Binary strings** — byte-array discipline when the codec lifts.

## Real limitations (ranked, unchanged by Tier A)

1. No sockets in the runtime → the networked half of the harness never
   compiles natively without FFI.
2. No process pipes → `run_command` confinement needs an FFI rebuild to keep
   its guarantees.
3. No JSON/OpenSSL/Digest stdlib → Tier B FFI; Tier A ships pure-Ruby
   substitutes so the kernel does not wait.
4. No `eval`/string-eval/`method_missing`/dynamic `define_method` → the DSL
   survives (block `instance_eval` compiles); genuinely dynamic code does not.
5. **Threads are true-parallel (no GVL).** Kernel state that relied on the
   GVL for benign races must be audited under Spinel's memory model —
   tracked in `docs/spinel/spec-tier-a.md` §Memory model. Mutexes are
   supported; the fixes are mechanical where needed.
6. No Encoding model (UTF-8/ASCII assumed) — the MQTT5 codec's binary-string
   discipline needs care when its codec is lifted.
7. Whole-program compile-time world — runtime plugin discovery stays
   data-driven (manifests are JSON); nothing dynamic loads code.

## Verification status

| Claim | Status |
|---|---|
| Kernel is subset-clean (no eval/metaprogramming/keyword_init Structs/missing stdlibs) | **VERIFIED** — `test/spinel_subset_test.rb` lint, 47 files |
| CRuby behavior unchanged | **VERIFIED** — 681 runs / 4393 assertions / 0 failures (seeds 16007-equivalent, 4242) |
| Pure JSON/SHA-256/base64/hex match stdlib/OpenSSL | **VERIFIED** on both runtimes (parity suite + native self-check) |
| Kernel self-check | **VERIFIED NATIVE** — `build/runes-kernel selfcheck` → `KERNEL SELFCHECK OK (70 checks)` |
| Compiles under Spinel | **VERIFIED** — `SPINEL=./spinel/bin/spinel ruby scripts/spinel_build.rb` (first build 2026-10-01; compiler quirks and workarounds in `docs/spinel/spec-tier-a.md` §First native build) |
