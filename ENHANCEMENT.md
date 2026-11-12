# Enhancements — open threads, scoped for the next session

The ordered "what's next" list. Each entry says what exists, what is
open, and how to pick it up. For the fleet/observatory split see
`STATE.md` ("Next, in order") and `docs/OBSERVATORY_ROADMAP.md`; this file
is the enhancement backlog that survives a session close. Nothing here is
vapour — every item is specified, spiked, or scoped.

Status of the world at the last update (2026-11-12): parent suite
**1148 runs / 6802 assertions / 0 failures, 3 skips**; observatory
**241 / 1220 / 0**. The `/spinel` compiler checkout is now in-repo at pin
a2bd89005 with a prebuilt `spinel/bin/spinel` (kernel self-check 70/70,
compiled fleet runtime green — §1 below); `wasi-sdk` 25.0 is in `tmp/`
for the S1 wasm spike.

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

**Landed 2026-11-12: the compiled fleet runtime.** A loaded world bakes to
pure data at build time (`Runes::Fleet.bake_file`,
`scripts/fleet_bake.rb` → `spin/baked_world.json`; actions probed to data,
guards dropped and recorded) and compiles into `spin/fleet_kernel.rb` —
`build/runes-fleet-kernel fleet` runs the engine in-guest over the
in-process transport and prints `FLEET KERNEL OK` (verified natively,
arm64, pin a2bd89005; CRuby parity prints the identical journal). The
engine executes baked actions directly (`rule.baked_actions`, no block).
The `/spinel` checkout now exists in-repo at pin a2bd89005 with a prebuilt
`spinel/bin/spinel`, and `wasi-sdk` 25.0 sits in
`tmp/wasi-sdk-25.0-arm64-macos`, so the S1 spike (Spinel-C → wasi-sdk
hello world, `--target=wasm32-wasi`) is unblocked on both fronts.

**Remaining in §1:** only the S1 wasm spike itself — compile
`spin/kernel.rb` to `wasm32-wasi` with the wasi-sdk clang and run it under
a wasm host (wasmtime), then the same baked-world bridge in a wasm guest
instead of a native kernel. The native compiled fleet runtime — the item
this section was tracking — is done; see `DEVELOPMENT_LOG.md` (2026-11-12)
for the receipts and the one compiler finding (top-level `map(&:sym)`
miscompiles once `fleet/engine.rb` is in the image; block form used).

## 2. Fleet — planner-driven worlds and spec v0.2

**Landed 2026-11-11:** planner-driven worlds (`/done` emits a `.fleet.rb`
world from the session, validated fail-closed by the real loader before it
is written to `worlds/`; `RUNES_FLEET_EMIT=0` opts out), **rule
priorities** (`on :x, priority: N` — higher first, ties in declaration
order), and **mutable cells** (`cell :name, initial: v` + `set` in rules,
every set journaled as a `fact_set` WAL entry before it is applied).
**Nested fleets landed 2026-11-12** (lexical, analyzable import):
`import "sub.fleet.rb"` loads the sub-world through the same fail-closed
loader (cycle-detected) and merges it under a `sub__` namespace prefix —
roles/channels/facts/schedules/schemas prefixed, edges re-pointed, imported
rules wrapped in a prefixing context so their action targets resolve in the
merged world. Tests cover merge, firing with prefixed targets, cycles, and
missing files. The Phase-40 review fixes (whole-rule refusal on raise,
boot-first journaling, reserved-word interception incl. the `Kernel#spawn`
bypass) are the ground these build on.

## 3. Observatory — the remaining P1 views

**Landed 2026-11-11:** `O1.5` alerts (the `Alert` model — dedupe by
kind+subject, count, ack — plus detectors for impersonation and signature
failure running in ingest, `/alerts` page with ack and a nav badge) and
`O1.6` the plugin catalog (`/plugins` renders the seven runes straight
from the registry). **O1.7 landed 2026-11-12:** the plan chain on the
interaction page (`PlanChain` joins prompt → plan → tool calls → verdict
from the request's packets). Still open: `O0.4`
retention/rollups at real volume (`/feed` payload bytes and unbounded
per-agent rendering are the measured limits). Auth gates `O1.2`
(launch-from-UI is remote execution).

## 4. Pipeline promotion

**Done 2026-11-11:** `bin/runes-kanban` validates one `.mmd` file or a
whole `--tree`, with the same rules as their `validate_mermaid.rb`
(`Runes::Kanban.validate`), exit 1 on any failure; covered by
`test/kanban_test.rb` and shipped in the gemspec executables. **Also done:**
the `kanban_query` MCP builtin on `bin/runes-mcp` — any harness can ask the
CRM kanban mid-task over `tools/call` (workspace-confined, guarded as
`fs_read`, returns validated tasks by column as JSON); covered by a
subprocess test in `test/mcp_test.rb`. (Also fixed: the binstub now wires
the JSON backend, so the guard no longer fails closed on `read_file`.)

**Also done 2026-11-11 — the pre-swarm discovery phase** (design:
`docs/runes-pre-swarm-discovery-phase-for-lfm3-1-7b.md`): workflow-layer
prototype `examples/discover_codebase.rb` + `Runes::Discovery`
(renderings, loop detector, anchor resolution, card assembly) + the
swarm-layer contract diff (`discovery.v1`/`finding.v1` in
`Capacity::SCHEMAS`, `discovery_insufficient`/`anchor_unresolved`/
`loop_detected` in `Decision::REASONS`, `discoverer` hop). Offline-tested
end to end in `test/discovery_test.rb`. **Three-arm benchmark done
2026-11-12** (`bench/discovery/results/2026-11-12-discovery.md`): full
discovery answers 4/4 subproblems with resolved anchors (anchor_pass 1.00,
0 loop events, 5 calls) vs the tree-only control at 0/4 — the
exploration-modality lift the swarm pilots could not produce; the external
arm is infra (no endpoint). Still open from the design: mission acceptance
in `/build` as the downstream metric, and the d1 sufficiency-judge +
ideate A‖B fan-out in the contracted layer.

**Done 2026-11-11:** `bin/runes-kanban` validates one `.mmd` file or a
whole `--tree`, with the same rules as their `validate_mermaid.rb`
(`Runes::Kanban.validate`), exit 1 on any failure; covered by
`test/kanban_test.rb` and shipped in the gemspec executables. **Also done:**
the `kanban_query` MCP builtin on `bin/runes-mcp` — any harness can ask the
CRM kanban mid-task over `tools/call` (workspace-confined, guarded as
`fs_read`, returns validated tasks by column as JSON); covered by a
subprocess test in `test/mcp_test.rb`. (Also fixed: the binstub now wires
the JSON backend, so the guard no longer fails closed on `read_file`.)

## 5. Optional / gated

Durable `RequestLedger` — only if MQTT session expiry gets turned on
(today clean sessions mean the broker does not replay either).

## 6. Cycle 43 — the LFM3 team pilot (NO-GO ×3, thread CLOSED 2026-11-11)

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
the 0.30 sufficiency gate at 0.10–0.25).

**Closed 2026-11-11 (third run `2026-11-11-rerun3-decision.md`): NO-GO a
third time — thread closed as a published negative result** (PRD stop
condition). The 512-token-cap hypothesis was tested and refuted (team-full
6/24 → 3/24; the model echoes prompt scaffolding at higher caps; cap reverted
to 320). What the third run did land: the out-of-sample calibration set
(`bench/swarm/calibration-set.json`, 20 items disjoint from the 24 cases,
ECE 0.165 — validates the 0.30 sufficiency threshold; builder
`bench/swarm/build_calibration_set.rb`; the conductor reads the threshold
from `--calibration`). Remaining gap is model capability, not harness:
citation-grounded answers at 320 tokens, audio perception sufficiency
(0.07–0.25 vs 0.30; the calibration set is text/image-weighted). Reopen only
on a different model or suite.
