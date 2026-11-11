# Enhancements — open threads, scoped for the next session

The ordered "what's next" list. Each entry says what exists, what is
open, and how to pick it up. For the fleet/observatory split see
`STATE.md` ("Next, in order") and `docs/OBSERVATORY_ROADMAP.md`; this file
is the enhancement backlog that survives a session close. Nothing here is
vapour — every item is specified, spiked, or scoped.

Status of the world at the last update (2026-10-24, Phases 40–42):
parent suite **764 / 4810 / 0 failures** with SPINEL set (pin a2bd89005,
kernel 70/70, L3 fleet gate green, stub workarounds deleted after
matz/spinel#7213 + #6741 were fixed upstream); observatory **231 / 1148 /
0** (`FleetDeclaration` renders the declared fleet on `/topology`; the
parked 22-error suite batch was one missing
`require "runes/backends/cruby"`).

---

## 1. WASI — the compiled fleet runtime (the round trip is closed)

**Closed 2026-10-24.** The real-wasm canary passes. The wedge was not a WASI
preopen op: wasmtime-ruby holds the CRuby GVL while guest code executes, so
the in-process VM starved the adapter's pump thread and every timer.
Micro-probes cleared boot, `sleep`, `Dir.glob` (empty and populated),
`Dir.mkdir`/`EEXIST`, `File.delete` and `File.rename`; the VM now runs in a
child OS process (`wasm/wasm_host.rb`), and the whole file is 12 runs / 30
assertions / 0 skips under `RUNES_WASM=real` (~12 s, mostly module compile).
Full diagnosis and receipts: `docs/wasi-transport-guest.md`.

**What exists (Phase 41).** `Runes::Transport::WasiGuest`
(`lib/runes/transport/wasi_guest.rb`) + `wasm/transport_guest.rb`: the
fabric state (subscriptions, retained, shared-group round-robin) lives in
a long-lived guest behind a framed file bridge (numbered JSON files on the
WASI preopen, `tmp`+`rename` both directions, acks after apply). 11
hermetic tests green via a CRuby-spawned guest; `Transport.build(kind:
"wasi_guest")` wires it.

**Next: the compiled fleet runtime.** Bake a loaded world into a Spinel
kernel — the workflow pattern — and implement the *same* bridge protocol
in-guest. The file bridge is the seam; the real-wasm canary was its gate,
and it is now green. The Spinel kernel itself compiles and self-checks
70/70 on pin a2bd89005 (verified 2026-10-24), so the compiler side is
ready; what remains is extending the kernel-subset discipline to the
loaded-world/fleet code and reusing the guest bridge.

**How to pick it up.** Start from `docs/FLEET_DSL.md` §11 and the gate
stub (`test/fixtures/fleet/spinel_gate_stub.rb`): the stub proves a fleet
file can compile whole-program, but it does not *run* a world. The next
step is a minimal compiled guest that boots with a baked world and answers
the same inbox/outbox frames as `wasm/transport_guest.rb`; the existing
CRuby-spawned tests are the contract, and the real-wasm canary is the
runtime check.

## 2. Fleet — planner-driven worlds and spec v0.2

Chat-driven world changes through the planner (`/goal → /done` emitting
Fleet DSL as its canonical output — spec §1.1); then the deferred v0.2
items from `docs/FLEET_DSL.md` §14: **mutable cells** (needs a write-ahead
journal before it can ship — §5.3.5 determinism), **nested fleets**
(lexical, analyzable import), **rule priorities** (explicit `priority:`
over declaration order). The Phase-40 review fixes (whole-rule refusal on
raise, boot-first journaling, reserved-word interception incl. the
`Kernel#spawn` bypass) are the ground these build on.

## 3. Observatory — the remaining P1 views

`O1.5` alerts (the `Alert` row; impersonation and guard-denial detectors
already run — they need a row and an ack), `O1.6` the plugin catalog
(nearly free, renders the registry), `O1.7` the plan chain
(prompt → plan → tool calls → evidence → verdict), then `O0.4`
retention/rollups at real volume (`/feed` payload bytes and unbounded
per-agent rendering are the measured limits). Auth gates `O1.2`
(launch-from-UI is remote execution).

## 4. Pipeline promotion

An MCP query surface so any harness can ask the CRM kanban mid-task — still
open. **Done 2026-11-11:** `bin/runes-kanban` validates one `.mmd` file or a
whole `--tree`, with the same rules as their `validate_mermaid.rb`
(`Runes::Kanban.validate`), exit 1 on any failure; covered by
`test/kanban_test.rb` and shipped in the gemspec executables.

## 5. Optional / gated

Durable `RequestLedger` — only if MQTT session expiry gets turned on
(today clean sessions mean the broker does not replay either).

## 6. Cycle 43 — the LFM3 team pilot (NO-GO, thread open)

**Verdict: NO-GO** (2026-11-04, 24 cases × 1 seed, cold command mode, real
MLX packs). Decision record: `bench/swarm/results/2026-11-04-pilot.md`;
report: `bench/swarm/results/2026-11-04-pilot-report.md` + `.json`.
team-full 4/24 with 44 contract violations, decline recall 0.80, ECE 0.54;
the same-model-3x control passed 7/14 on the same cases, so extra calls do
not rescue the team. Unvalidated hops 0 everywhere; the `adapter` arm is
infra (no LoRA adapter exists — profile-only only); `frontier-1x` not run
(no endpoint).

**Next thread:** the echo-envelope contract, not team shape — the 1.7B at
temperature 0.1 cannot reliably echo IDENTITY/CAPACITIES/DECISION/BODY
(`output_schema_unknown`, `identity_missing`, `citation_missing` dominate).
Move text roles to stamp mode (adapter stamps identity/capacity; model
returns DECISION+BODY only) or add constrained decoding, then re-run
`text-lite`/`team-full` on the 14 text-subset cases. In parallel: the
perception-sufficiency gate (0.30) rejects every audio perception (d1 scores
0.03–0.07), and d1-only false-accepts O1/O2 — wire the scope answer to a
decline. Harness: `bench/swarm/` (runner, 24 cases, fixtures, README,
calibration bands); suite green at 1121 runs / 0 failures.

**Update 2026-11-11 (re-run `2026-11-11-rerun2-decision.md`, still NO-GO):**
the three harness fixes landed and are measured — stamp-mode envelopes
(`Envelope.stamp_text`, shared conductor + solo path), safety verdicts
gating even a forced shape, and declared capacities + known limits in the
triage state. d1-only decline recall 0.00 → **1.00**, false-answer 1.00 →
**0.00** (O1/O2 decline on every conductor arm); solo-1.7B 2/14 → **7/14**;
team-full 4/24 → 6/24, ECE 0.537 → 0.359; envelope-structure violations
nearly gone (remaining: `citation_missing`, `truncated_suspect`). Text lift
vs the stronger solo baseline is now **−14.3 pp** (team-full 0.36 vs solo
0.50); modality lift still negative (0.10 vs solo-VL 0.75; audio still below
the 0.30 sufficiency gate at 0.10–0.25). **Next thread now:** answer quality
at the 320-token cap (raise per-role max tokens or tighten checks), plus a
real out-of-sample calibration set for the sufficiency threshold.
