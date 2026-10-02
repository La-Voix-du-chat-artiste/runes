# Runes Development Log & Plan

> The audit documents this log cites by name (`doc.md`, `doc4.md`, `doc5.md`,
> `RECOVERY.md`, `Runes-MQTT-Overview.pdf`) live in
> [`docs/How this started/`](docs/How%20this%20started/README.md), with a note on
> what each round found. They keep their original filenames on purpose.


## Objective
Recursive Ruby harness: an LLM-planned agent loop rides on top of an
MQTT messaging fabric, with trusted host tools and (opt-in) WASM
sandboxes for untrusted tool code.

**Where this stands now (2026-09-10):** the full product loop works
live — `/goal` shapes an idea into an Epic, `/plan` refines it into a
Mission (ordered todos + JSON sidecar), `/build <mission>` executes
each todo through guarded tools with a fail-closed QA verifier and
crash resume. The planner uses native function calling by default
(opt-out `RUNES_USE_TOOLS=0`). **258 runs / 1059 assertions / 0
failures / 0 errors / 0 skips**, hermetic and fully offline (no live
API calls in tests — provider HTTP is faked with an injected dup
transport). Preferred provider is now **DeepSeek V4.1 Flash**
(`deepseek-flash`, reasoning effort high), then Synthetic, then
Cerebras; live-validated end-to-end (plan → write ×2 → generated
minitest green). A **Rails 8.1 observatory** (`runes_observer/`) watches
the fabric and serves a fleet + packet UI (Phase 15). See STATE.md for
the snapshot and Phases 14/15 below for the fourth-audit round
(`doc4.md`) and the observatory.

## Architecture Decisions

- **Reactive-messaging-first.** MQTT is the core runtime, not an
  afterthought. Prompts, tool calls, tool responses, agent cards,
  streaming progress — everything traverses the bus.
- **Trusted host + WASM tools (IronClaw-style).** The agent loop,
  credential store, and full MQTT client run in the host process.
  Untrusted tool code runs (optional, flag-gated) inside ruby.wasm via
  wasmtime-rb, with WASI providing the only I/O channel and fuel
  metering providing resource caps.
- **Capability guard, default-deny + per-tool manifests.** Policies
  for each tool live next to the tool implementation in
  `tools/<name>/capabilities.json` and are merged into the Guard at
  boot. Wildcards (`+`, `#`) supported. Fail-closed everywhere.
- **Workspace confinement.** Host-side `write_file` / `read_file` /
  `run_command` are confined to `RUNES_WORKSPACE` and refuse absolute
  paths, `..` escapes, and shell metacharacters.
- **Structured planner output.** Strict JSON primary, legacy text
  fallback. LLMClient can also use OpenAI-function-calling mode
  (`tools` parameter) and returns
  `{ ok:, mode: :content | :tool_calls, ... }` so the dispatcher
  adapts its parsing accordingly.

## Milestones

### Phase 1 — Core Infrastructure ✅
- Settings, Guard, Broker, VMManager (mock + real backends).

### Phase 2 — Agentic Brain ✅
- LLMClient (Cerebras), PlanParser (JSON + legacy text), Dispatcher
  end-to-end pipeline.

### Phase 3 — Interface ✅
- `bin/runes-daemon`, `bin/runes-client`, `bin/runes` (TUI skeleton).

### Phase 4 — Reactive Fabric ✅ (current)
- **Agent Cards.** Each dispatcher publishes a retained
  `runes/agents/<id>/card` at boot with its tools, workspace,
  wasm backend, and timestamps. Other dispatchers and dashboards can
  discover peers without polling.
- **Last Will & Testament.** Pre-registered on
  `runes/agents/<id>/status` at connect time. Unclean disconnects
  flip the retained status from `online` to `offline` (the broker
  stores the will per-client and fires it from the `ensure` path).
- **Streaming Progress.** Each prompt gets a `request_id`; the
  dispatcher publishes progress events on
  `runes/prompts/<request_id>/progress` at every lifecycle transition
  (prompt_received, plan_ready, step_start, step_end, prompt_complete).
- **Tool Manifest.** `tools/<name>/` contains:
    - `card.json` — A2A-style metadata (name/desc/version/args)
    - `capabilities.json` — MQTT topic ACLs for that tool
    - `run.rb` — implementation (currently host-side; later WASM)
  Scanned by `ToolRegistry` at boot and merged into Guard.
- **Function-Calling Mode.** `LLMClient.call(prompt, tools: [...])`
  sends OpenAI-style function schemas and parses `tool_calls` from
  the response. Doesn't yet run by default (env flag planned).

## Defects Fixed (Retrospective)

1. Guard default-allow → default-deny, fail-closed on JSON errors
2. `run_command` raw shell → workspace-confined, metachar-free, blocklist
3. `write_file` absolute paths / `..` escape → confined
4. Hardcoded `$HOME` paths in Settings / daemon → ROOT-relative
5. Dispatcher swallowed MQTT loop errors → per-message isolation + retry
6. Broker packet length encoding broken > 127 B → correct encoding
7. Broker SUBSCRIBE assumed one filter → multi-filter + SUBACK QoS echo
8. Broker had no wildcards → `+` / `#` implemented
9. PlanParser lived inline in dispatcher → extracted to tested class
10. LLMClient returned raw error strings as if they were plans →
    structured `{ ok:, content:, error: }` result Hash

## Defects Fixed (Phase 6 — security & correctness audit)

1. Guard instances shared one mutable policy hash (`DEFAULT_POLICY.dup`
   shallow copy) → per-instance deep copy; verified cross-contamination
2. `run_command` metachar denylist missed `$()` substitution and
   newline separators (verified executable) → `$`, backtick, CR/LF,
   NULL blocked; optional binary allowlist (`RUNES_CMD_ALLOWLIST`)
3. Guard never consulted on the planner-driven path → enforced now
   (`fs_write`/`fs_read`/`exec` actions; baseline grants in Guard,
   overridable by policy file or tool manifests)
4. `safe_path` lexical-only expansion → symlink escapes blocked via
   realpath of deepest existing ancestor, re-checked against the
   workspace's realpath (macOS `/var` vs `/private/var` handled)
5. `runes-client` published before subscribing (response race, 120 s
   hang) → subscribe-first + request-id envelope; correlated replies
   on `runes/prompts/<req>/response`
6. Broker ran subscriber callbacks and socket writes under the global
   mutex (recursive-publish deadlock; slow-socket stalls) → fan-out
   snapshot delivered outside the lock; per-socket write serialization
7. Broker accepted unbounded declared packet sizes (OOM DoS) → 1 MiB
   packet + retained caps; oversized-packet clients dropped
8. Real WASM backend never received tool code (stdin injection was a
   no-op stub) → per-run Store + WasiConfig with code on stdin;
   symbol-perm API fix; fuel set before *and* after instantiation
   (fresh stores start at 0); default budget 5B (boot ≈1B, measured)
9. `run_command` had no timeout/output cap (hang + OOM) → 10 s default
   timeout with kill, 64 KiB capture cap, cap-aware process kill
10. Unbounded plan size / prompt size → `RUNES_MAX_STEPS` (25) and
    32 KiB prompt cap
11. Tool-request denials published to the topic the policy just denied
    → denials go to `runes/tools/<t>/error`
12. Boot race: agent card announced before subscriptions set →
    subscribe-before-announce
13. Delegation responses unroutable back to the requester → envelope
    carries `request_id`; replies on `runes/agents/<from>/tasks/<req>/response`
14. "Durable" log lived only in the in-memory broker → JSONL journal
    at `log/journal.jsonl` + `bin/runes-replay` (show / `--replay`)
15. LLM system prompt conflicted with function-calling mode → dedicated
    tool-mode system prompt

## Enhancements Implemented (this round)

- Broker: retained messages, LWT, in-process pub/sub for embedded use
- Dispatcher: agent card publication, boot-time status, per-request
  streaming progress topics
- ToolRegistry: scans `tools/`, aggregates cards + policy fragments
- Guard: `merge_fragment!` for dynamic tool-policy registration
- LLMClient: OpenAI-style function schemas via `builtin_schemas`,
  dual-mode `call` (content vs. tool_calls)
- Tests: 46 examples / 117 assertions; unit + integration coverage of
  every new feature

## Enhancements Implemented (Phase 5 — this round)

- **Function-calling enabled.** `RUNES_USE_TOOLS=1` switches
  `Dispatcher#handle_prompt` to the tool-call path: the planner
  receives `LLMClient.builtin_schemas(extra: registry cards)` and may
  reply with structured `tool_calls`, which map directly to plan steps.
- **Reactive TUI.** `bin/runes` no longer polls the dispatcher object;
  it subscribes to `runes/agents/+/card`, `runes/agents/+/status`,
  `runes/prompts/response` and `runes/prompts/+/progress` and redraws
  only when events arrive. The input line publishes to
  `runes/prompts`.
- **Durable prompt log.** Every prompt lifecycle end is published as a
  JSON envelope on `runes/_log/prompts`, with a retained latest-entry
  snapshot on `runes/_log/prompts/latest`.
- **Cross-dispatcher delegation.** Dispatchers subscribe on their own
  `runes/agents/<id>/tasks` topic at boot; `Dispatcher#delegate_to`
  sends a `{prompt:, from:}` envelope to a peer, which executes it
  through the normal prompt pipeline.
- **Manifest tools executed in the WASM sandbox.** Non-builtin tools
  with `tools/<name>/run.rb` now run through `VMManager` (real ruby.wasm
  or mock backend); STDIN arg reads are rewritten to a workspace-hosted
  args file that is cleaned up afterwards.
- Tests: 56 examples / 146 assertions; new
  `test/dispatcher_enhancements_test.rb` covers all of the above.

## Enhancements Implemented (Phase 6 — this round)

- Guard: deep-copied per-instance policy, builtin baseline grants,
  enforcement on the planner path (`fs_write`/`fs_read`/`exec`)
- run_command: injection-proof blocklist, optional allowlist, timeout,
  output cap (all env-tunable)
- safe_path: symlink-escape proof (realpath containment)
- runes-client: subscribe-first, request-id envelope, correlated reply
  topics
- Dispatcher: step/prompt caps, boot-order fix, denial error topic,
  delegation reply correlation
- Broker: packet/retained caps, lock-free fan-out, per-socket write
  serialization
- VMManager: working real backend (per-run Store, stdin code, 5B fuel)
- Durable JSONL journal + `bin/runes-replay`
- LLM: tool-mode system prompt
- Tests: 74 examples / 181 assertions; new `test/security_fixes_test.rb`
  (18 regression tests)

## Enhancements Implemented (Phase 7 — second audit, this round)

Defects found & fixed (each verified before the fix):

1. Tool-RPC path fed `args.to_json` to the VM as Ruby source — the
   tool's `run.rb` never ran (mock backend masked it) → RPC non-builtins
   now route through `execute_manifest_tool`; broken `execute_in_wasm`
   removed
2. Remote `request_id` used verbatim in topic names (topic injection:
   `../../evil` accepted) → sanitized to `[A-Za-z0-9_-]{1,32}`;
   generated ids lengthened 8 → 12 hex chars
3. `read_file` slurped unbounded files → `RUNES_READ_CAP` (1 MiB);
   `write_file` content → `RUNES_WRITE_CAP` (1 MiB)
4. Guard treated `#` as a wildcard anywhere in a pattern (over-permissive
   vs MQTT spec) → wildcard only as the final level; elsewhere literal
5. Delegation replies published but never consumed → dispatchers
   subscribe `…/tasks/+/response` and surface peer results globally
6. Retained cap dropped the NEW message when full → evicts the OLDEST
7. Dead `@broker` instance removed from Dispatcher
8. Journal grows forever → 10 MiB rotation to `journal.jsonl.1`
9. `STDIN.read` rewrite was an exact-string gsub → tolerant regex +
   documented tool contract in `tools/echo/run.rb`
10. LLM 429/5xx failed prompts outright → 3 retries with exponential
    backoff
11. `MAX_PROMPT_BYTES` truncation silent → `prompt_truncated` event
12. TUI missed correlated replies → subscribes `runes/prompts/+/response`

Enhancements:

- **Concurrent prompt pipeline**: prompts run off the reactive loop in
  bounded workers (`RUNES_MAX_CONCURRENT=4`, inline backpressure at
  cap) — one slow LLM call no longer stalls the fleet. Journal appends
  serialized across workers; `mqtt` gem write-safety verified.
- **Process-group kill**: `run_confined` spawns with `pgroup: true` and
  signals the negative pid on timeout/cap — no orphaned grandchildren
  (verified with a surviving `sleep 30`).
- README: allowlist-interpreter security note; new env vars documented
- Tests: 89 examples / 217 assertions; new `test/second_audit_test.rb`
  (15 regression tests); real-backend RPC path re-verified end-to-end

## Phase 8 — Multi-Provider LLM Router & Real-World Validation

### Router (`lib/runes/core/llm_client.rb`)
- `PROVIDERS` registry of OpenAI-compatible providers: endpoint, key
  env vars (`SYNTHETIC_API_KEY`/`SYNTHETIC`, `CEREBRAS_API_KEY`/`CEREBRAS`),
  default + seed model, aliases, sampling strategy
- Synthetic: `syn:large:text` = GLM-5.3-Flash; variation expresses as
  `reasoning_effort` (high/max/low) instead of temperature
- Resolution: call arg > `RUNES_DEFAULT_*` env > DB > provider default;
  key-missing fallthrough with notices; unknown-model re-derivation
- Pure `resolve_route` / `build_payload` split from HTTP for testing
- `RUNES_LLM_TIMEOUT_S` (180 s default); timeout-exception retries
- Settings seeds a fresh DB for whichever provider has a key

### Real-world validation (no stubs)
- `demo/hello_world_live.rb`: embedded broker + live Synthetic
  GLM-5.3-Flash (high): plan → 2× write_file → `ruby hello_test.rb`
  (exit=0, minitest green in-step) → correlated reply (~55 s) → journal
  entry. Verdict: ALL CHECKS PASSED.
- Shipped-binaries path: real mosquitto on 1883 + `bin/runes-daemon` +
  `bin/runes-client` — correlated reply received; guard blocked the
  model's `2>&1` step before the fd-to-fd allowance was added (now
  allowed: `2>&1`/`1>&2` only; all file redirection stays blocked)
- Tests: 107 examples / 267 assertions (incl. key-gated live call)

## Phase 9 — Broadcast Lease & Workspace Safety (incident-driven)

### Incident
User reported `hello.rb`/`test_hello.rb` appearing in `~/Boxes`: two
dispatchers were subscribed to the broadcast topic `runes/prompts` and
each executed the same prompt; the second had a workspace that resolved
to its launch directory (`Settings#workspace_root` defaulted to
`Dir.pwd`).

### Fixes
- **Claim/lease protocol** (`handle_broadcast_prompt`): every agent
  claims on `runes/prompts/<req>/claim`; after a collection window the
  lexicographically smallest claimant executes, the rest stand down.
  Shared request ids for plain prompts via SHA-256 digest of the prompt
  text (`prompt_digest_id`); TTL'd re-execution guard
  (`RUNES_EXEC_TTL_S`, default 60 s); delegated tasks skip the race.
- **Deterministic workspace default**: `<root>/workspace/` instead of
  `Dir.pwd`; `RUNES_WORKSPACE` still overrides; dispatcher logs the
  workspace at boot.
- **Client visibility/targeting**: `runes-client --agents` (retained
  agent cards with workspaces), `--agent <id>` (task envelope via
  `runes/agents/<id>/tasks`, reply on the client's delegation reply
  topic).

### Verification

Final counts: parent **373 runs / 1693 assertions / 0 failures / 0 errors / 0 skips**; observatory **61 runs / 348 assertions / 0 failures**. The P1.6 split moved 463 lines out of `dispatcher.rb` (1968 → 1545) into `lib/runes/agent/{fabric,journal,session_store}.rb`. Two more bugs were found by the new tests during integration: the MQTT 5 client accepted a non-zero CONNACK reason code (so a 3.1.1 broker answering a v5 CONNECT with the v3 code 0x01 looked like a granted session, breaking `auto` probing), and the ACL generator still granted the deleted claim/started topics (done with least privilege in mind).
- New `test/broadcast_lease_test.rb`: two dispatchers on one broker,
  one broadcast prompt → exactly one executor (deterministic winner);
  digest-id sharing; addressed tasks skip the race; workspace default.
- Live: two daemons on mosquitto + one `runes-client` prompt → winner
  claimed ("2 agent(s) listening"), loser logged "standing down",
  files in exactly one workspace.
- `demo/hello_world_live.rb`: ALL CHECKS PASSED (31 s reply).
- Tests: 111 examples / 277 assertions.

## Phase 10 — Slash-Command Modes (/goal → Epic, /plan → Mission)

- **`LLMClient.chat(messages, system:, json:)`**: multi-turn support;
  `build_payload` generalized to message arrays (`json:` now explicit,
  default true for the legacy one-shot planner).
- **Envelope modes**: `{mode, session_id, control, epic_path}`; absent
  or unknown mode → build; conversational modes bypass the claim/lease;
  `epic_path` from clients validated against `docs/epics/`.
- **Goal pipeline**: per-session message store (`@sessions`), rubber-duck
  PM system prompt, `/done` renders the epic (fixed sections) to
  `docs/epics/<ts>-<slug>.md`; epic path becomes the dispatcher's
  `@latest_epic` (also restored at boot from the newest file).
- **Plan pipeline**: brief or latest epic → strict-JSON mission
  (`mission_title`, ordered todos with detail/acceptance); invalid JSON
  re-asked once, then fails loud; markdown checklist + JSON sidecar
  (`todos[].done: false`) written to `docs/missions/`.
- **TUI**: local slash parser (`/goal /done /plan /build /agents /help`
  — never published as prompt text), mode chip in the footer, rendering
  for `conversation` / `epic_written` / `mission_written` events;
  `/plan` without epic auto-opens goal mode.
- **`runes-client --mode goal|plan`**.
- Tests: 130 examples / 340 assertions; new `test/mode_commands_test.rb`
  (19 tests: envelope parsing, chat payload, goal flow, mission flow +
  re-ask/fail-loud, epic handoff, claim bypass, TUI parser).

## Phase 10.1 — Modes Review Fixes (audit-driven)

1. **Conversational lease** (`handle_conversational_broadcast`):
   goal/plan turns claimed on `runes/sessions/<lease_id>/claim` with the
   same deterministic min-wins protocol as build; lease ids are shared
   across agents (session id, or digest of prompt/epic path) — one
   answer per goal turn even on a multi-agent bus. Verified with two
   dispatchers on one broker + live run.
2. **Correlated error replies**: mission planner-error and
   persistent-invalid paths publish to the requester's reply topic
   (previously global-only → CLI hang).
3. **Ephemeral session ids** for sessionless goal turns (announced in
   the conversation event; no nil-key shared session).
4. **Epic validation**: render must contain `# Epic` + `##` sections;
   garbage → `epic_invalid` with the session kept open; failed render
   instruction popped so /done retries cleanly; disk-failure →
   `epic_write_failed`, session kept.
5. **Session hygiene**: per-session mutex, LRU cap (32), history cap
   (40 messages), idle TTL (30 min, `RUNES_SESSION_TTL_S`).
6. **TUI /done state machine**: goal mode held until `epic_written`
   (→ build) or error (→ retry notice); abandon notices on /goal
   restart and /build; newest epic on disk adopted at boot.
7. Small: LLMClient notices mutex; goal/plan prompt caps; parse_envelope
   dead assignment removed.
- Tests: 140 examples / 374 assertions (10 new regressions incl.
  two-dispatcher single-winner lease with real brokers).

## Phase 11 — Mission Executor (`/build <mission>`)

The final planned round: missions become executable.

### Design
- Envelope mode `mission` with `mission_path` (`latest` supported);
  leased like goal/plan (lease id = digest of the path — shared across
  agents).
- For each **pending** todo (sidecar `done: false`):
  1. `mission_step_start` event; the planner receives the todo +
     acceptance criteria and responds with a strict-JSON step plan.
  2. Steps execute through the same guarded tool pipeline as build
     mode (fs/exec guard, command hardening, caps).
  3. A fail-closed QA verifier (reasoning `low`, strict JSON
     `{verdict, reason}`) judges the acceptance criteria **against the
     recorded evidence only** — insufficient evidence = fail.
  4. pass → sidecar `done: true` + markdown re-rendered (`- [x]`);
     fail → stop (default) or continue with `RUNES_MISSION_CONTINUE=1`.
- Crash resume for free: done todos are skipped on the next `/build`.
- `mission_complete` only when ALL todos are done; a failed todo stays
  pending so a re-run retries it.
- Path safety: `resolve_mission_path` accepts `latest`, bare filenames
  inside `docs/missions/`, or absolute paths there — containment-checked
  via realpath; sidecar required (md alone is rejected).

### Live-learned lessons (baked into code)
- **Evidence-aware prompts**: the first live run failed todo 2 — the
  planner wrote the file but the verifier correctly refused ("only size
  reported, no content evidence"). Fix: `mission_step_prompt` now
  instructs the planner to ALWAYS finish with a verification step
  (read_file / short run_command) that produces evidence. Second run:
  both todos passed, 18 s total.
- **`parse_envelope` regression caught by tests**: the original charset
  guard rejected absolute mission paths — including the paths the
  dispatcher itself publishes in `mission_written` events. Mission
  paths never enter topic names, so only control characters are
  rejected now; containment is enforced by `valid_mission_path?`.
- Verifier semantics: a mission with a failed todo is NEVER "complete",
  even in continue mode — the failed todo stays pending for resume.

### Tests & validation
- `test/mission_executor_test.rb` (10 tests): happy path + sidecar sync,
  planner-prompt carries todo+acceptance, stop-on-fail, continue env,
  resume (done skipped), already-complete short-circuit, out-of-dir
  rejection, missing-sidecar rejection, lease-id sharing, mode parsing.
- Suite: **150 runs / 410 assertions / 0 failures**.
- Live: `demo/build_mission_live.rb` — ALL CHECKS PASSED (mission lease
  held, both todos executed + verified + ticked).

## Phase 12 — Function calling on by default (2026-09-07)

### What changed
- `Dispatcher#use_tool_calling?` is now **default-on**: the planner
  always receives OpenAI-style `tools` schemas and may answer with
  structured `tool_calls`. Opt OUT via `RUNES_USE_TOOLS=0` (also
  `false|no|off`) to get the legacy free-form JSON plan format.

### The gate: one live multi-tool run (new demo)
- `demo/tool_calls_live.rb` boots the embedded broker + a dispatcher on
  DEFAULT config (no env flag), spies on `LLMClient#call` via a
  prepended module, and asserts for THIS run: schemas were sent,
  the response mode was `:tool_calls` with >= 2 calls covering two
  distinct tools (write_file + run_command), artifacts are fresh
  (mtime >= run start), the generated script runs green, the
  run_command step produced output on the bus, and the journal entry
  is recorded under the client's request id.
- Result: **ALL CHECKS PASSED** — GLM-5.3-Flash returned both tool
  calls in a single response; reply in 12.1 s.

### Bug found and fixed during validation
- **Broadcast envelope ids were discarded**: `handle_broadcast_prompt`
  passed only the prompt TEXT back into `handle_prompt`, so
  `parse_envelope` re-derived a FRESH RANDOM request id
  (`SecureRandom.uuid[0,12]`). Progress events and journal entries were
  then keyed by an id no client could predict, while the claim race and
  the correlated reply used the envelope id. Caught because the demo's
  journal check (keyed by `toolcalls1`) failed while every other check
  passed.
- Fix: pass the FULL message through (`handle_prompt(client, message,
  reply_topic: ...)`) so the id — and envelope context — is re-derived
  deterministically by the same sanitizer the claim used. Plain prompts
  are unchanged. Regression test:
  `test_envelope_request_id_survives_the_claim_race`.

### Tests & validation
- `test/dispatcher_enhancements_test.rb`: default-on asserted, opt-out
  (`RUNES_USE_TOOLS=0`) asserted, tool-calls pipeline asserted with the
  flag UNSET.
- `test/broadcast_lease_test.rb`: +1 envelope-id correlation test.
- Suite: **152 runs / 412 assertions / 0 failures**.
- Live: `demo/tool_calls_live.rb` — ALL CHECKS PASSED (default path,
  flag unset).

## Session Closing Summary (2026-09-07)

This conversation took Runes from a Phase-4 fabric (46 tests) to a
complete intent→artifact→execution loop (152 tests), via twelve phases
of features, three security/correctness audits, and one real-world
duplicate-execution incident (fixed with the lease protocol). Key
survivor knowledge is in STATE.md (snapshot + runbook + hard-won
provider/sandbox notes) and README.md (full user doc). Next natural
rounds: broker auth, tool-result feedback in single build plans,
journal-based session replay.

## Roadmap

- [x] Function-calling default-on (live multi-tool gate:
  `demo/tool_calls_live.rb`); opt-out via `RUNES_USE_TOOLS=0`
- [x] WASM tool execution (`tools/echo` via ruby.wasm; real backend
  validated with a fuel budget + epoch wall-clock deadline)
- [x] TUI (`bin/runes`) reading agent cards + progress topics via
  retained-message subscription (no polling)
- [x] Cross-dispatcher task delegation (dispatcher A sends tool request
  to dispatcher B by naming it on a topic)
- [x] Durable journal via an append-only JSONL stream + `bin/runes-replay`
- [x] Multi-provider router: Synthetic, Cerebras, and **DeepSeek V4.1
  Flash** (preferred); provider order DeepSeek > Synthetic > Cerebras
- [x] Round 4 (`doc4.md`): single-winner claim protocol, authenticated
  tool RPC, confined `run_command`, mission evidence, offline hermetic
  test suite, `.gitignore`
- [ ] Bounded tool-result feedback loop for build plans (DeepSeek plans
  iteratively; the one-turn planner prompt is the interim mitigation)
- [ ] Broker auth / per-client ACLs (localhost-only today)
- [ ] openat-style write confinement (closes the symlink TOCTOU)
- [ ] More providers (Anthropic, OpenAI, local Ollama)

## Phase 13 — Third audit + repository recovery (2026-09-07)

### The audit (doc.md: 49 bugs, 22 security findings)

All findings fixed; highlights by severity:

- **HIGH**: provider keys no longer enter global ENV (settings parse
  `config/.env` internally; `run_command` children additionally get a
  scrubbed env via `unsetenv_others`) · broker `subscribe` no longer
  delivers retained messages under the global mutex (self-deadlock) ·
  broker body reads are time-boxed against the keepalive (slow-loris
  thread-pinning) · invalid `request_id`s fall back to a DETERMINISTIC
  digest (a random fallback made every agent claim a different topic
  and execute) · stale claims are timestamped and evicted (a crashed
  lease-winner can no longer wedge a session) · WASM guests run under
  an epoch-interruption wall-clock deadline (`RUNES_WASM_TIMEOUT_S`,
  default 30 s; fuel still bounds compute) · TUI strips control
  characters at the event boundary (escape-sequence injection) ·
  VMManager defaults to NO workspace preopen (fail-closed; explicit
  `workspace:` required).
- **MEDIUM**: atomic dedup before the claim window (identical prompts
  within the window no longer double-execute) · `@claims`/`@executed`
  bounded · tool RPCs dispatched off the reactive loop · builtin tool
  RPC path made reachable · guard: malformed fragments fail closed,
  known tools with missing actions fail closed, `#` never matches the
  empty topic, manifest fragments additive-only for builtins (loud
  warning on override attempts) · mission/epic containment requires
  the path separator (sibling-prefix dirs rejected) · mission verifier
  parses the WHOLE reply as strict JSON (injection-proof) · mission
  sidecar + artifact writes are tmp-file+rename atomic · SQLite
  busy_timeout(5s)+WAL · settings seeding transactional and
  read-only-safe · provider switch re-derives `default_model` · tool
  registry: TOCTOU-safe scan, manifest parse caps, realpath
  containment, manifest digests, rescan support · LLM: lazy timeout,
  fresh connection per attempt, total retry deadline, notices bounded
  + copied, non-Array messages rejected, error bodies sanitized and
  truncated, provider-fallback opt-out, parse-size caps, Retry-After,
  `finish_reason=length` surfaced · broker: QoS 1/2 acked with the
  packet id parsed out of the body, LWT fires via handler ensure,
  raising in-process callbacks removed from their own filter only,
  SUBACK varint, keepalive 0 honored, malformed remaining-length
  drops, wildcard PUBLISH topics rejected, UNSUBSCRIBE (wire +
  programmatic), fan-out dedup, retained cap protects stored state,
  connection/subscription caps · VMManager: `with_vm` + double-release
  guard, truncation flag, mock results marked, `backend: :real` with a
  missing binary raises · TUI/CLI: /done gated on the matching request
  id, pending id set before publish, publish failures roll back mode,
  reader reconnects with backoff, registry column clamped, agent ids
  sanitized, status/agent-count caps, replay uses fresh request ids
  and rejects negative `-n`, daemon logs fatal backtraces and drops
  the unused `async` require.
- **LOW/INFO**: dead code removed (`set_last_will`, `already_executed?`,
  dead `resolve_mission_path` branch), `/build latest` restored at boot,
  sole-goal-session `/done` for one-shot flows, prompt-redaction hook
  (`RUNES_REDACT_PROMPTS=1`), guard inert-mode warning, structured deny
  logging, journal tail-reading, bracketed-paste robustness, reply
  correlation, history bound.

### The recovery incident (documented so it never repeats)

During verification, a reconstructed test
(`test_tui_publish_failure_rolls_back_goal_mode`) created the TUI with
the DEFAULT root — the project root — and its `ensure` block called
`FileUtils.remove_entry(root)`: the whole repository was deleted
mid-suite (twice). The project was rebuilt from session context plus a
partial snapshot. Guards now in place:

- TUI tests always pass an explicit tmpdir root;
- every test-side cleanup is restricted to paths under `Dir.tmpdir`;
- `test/mission_executor_test.rb` uses a tmp settings root so mission
  fixtures never land in `docs/missions/`.

House rule (new, hardest-won): **any `ensure`-side recursive delete in
tests must assert the path is under `Dir.tmpdir` first.**

### Tests
- Suite: **184 runs / 453 assertions / 0 failures / 1 skip** (the skip
  is the key-gated live smoke call). New `test/third_audit_test.rb`
  (33 regression tests covering the audit fixes).

---

## Phase 14 — Fourth audit (`doc4.md`) + DeepSeek V4.1 Flash

Trigger: `doc4.md` (round-4 review). Every finding was reproduced before
being fixed, and the whole round was driven by one hard requirement from
the operator: **tests must never use an API key** — the provider call is
faked with a dup transport instead.

### The headline fixes

- **Claim protocol was not single-winner (B4-3/E4-3).** The saturated
  path ran the prompt pipeline *inline on the reactive loop*; while it
  slept through the 0.6 s claim window it could not read peer claims, so
  every saturated agent computed `claims.min == self` and executed. A
  two-agent PoC reproduced the same broadcast being planned twice.
  Fix: a fixed worker pool drained from a bounded `SizedQueue` (a full
  queue answers `busy`), plus a durable **execution announcement**
  (`runes/prompts/<req>/started`, also `runes/sessions/<lease>/started`)
  kept for `RUNES_EXEC_TTL_S`. The winner announces, sleeps
  `RUNES_STARTED_GRACE_S`, re-reads, and stands down if an earlier
  announcement exists (ties break on the smallest agent id). A delayed
  claimant now learns the work is taken even though its claim window
  closed long ago.
- **Tool RPC was an unauthenticated RCE endpoint (S4-1/E4-6).** A PoC
  client with no credentials ran `touch PWNED` through
  `runes/tools/run_command/request`. The topic is now **off unless
  `RUNES_TOOL_RPC=1`**, and when on every request must carry
  `RUNES_RPC_SECRET` (constant-time compare) or it is refused on the
  tool's `error` topic.
- **`run_command` could delete the world (S4-2/E4-5).** `dangerous_command?`
  only caught the literal `rm -rf /`; `rm -rf ..` and `rm -rf ~` passed,
  and `~` is shell-expanded. A PoC deleted a sibling of the workspace.
  Every path token that leaves the workspace (`..` segment, absolute
  path, `~`) is now refused before execution, on top of the existing
  metachar/destructive filters.
- **Mission pipeline was three defects deep (B4-5/B4-6/E4-7/E4-8).**
  Mission steps called `@llm.call` directly, silently bypassing the
  function-calling default and the manifest tool schemas; the QA verifier
  only ever saw the 200-char `summarize` line. Both now use the shared
  `plan_for` entry point, and the verifier receives bounded raw evidence
  (8 KiB per todo, explicitly marked when clipped, with a distinct
  "no evidence" case).
- **`extract_json_object` was brace-blind (B4-4/E4-4).** A mission whose
  todo text contained a single unbalanced `{` or `}` was rejected after
  burning a re-ask. Extraction now lives in `lib/runes/core/json_scan.rb`
  and is shared with `PlanParser`.
- **Provider error bodies crashed the error path (B4-2/E4-9).**
  `parsed.dig('error', 'message')` raised `TypeError` when `error` was a
  string (many gateways, including the Synthetic 401 that made the suite
  red), masking the real HTTP status. Error extraction is now
  shape-proof for string/object/array/number/plain-text bodies.
- **Durability (B4-7/E4-11/S4-5).** Journal rotation used a shared fixed
  `.1` name and a per-process mutex, so a daemon and a CLI could clobber
  each other's archive; it now rotates to a timestamped name under a
  cross-process `flock`. The broker's retained store gained an 8 MiB
  byte budget on top of the 1000-topic cap.
- **Smaller correctness fixes.** `write_file` accepts empty content
  (touch/truncate) and only rejects a missing key (B4-8); prompt
  truncation is byte-bounded and encoding-safe rather than a character
  slice (B4-10); `RUNES_WASM`/`RUNES_WASM_TIMEOUT_S` are read through
  `Settings#env` so `config/.env` is honoured (B4-9); the guard is asked
  about the *resolved* workspace-relative path rather than the raw
  planner string (S4-4); `execute_manifest_tool` resolves `run.rb`
  through the registry's `tools_dir` instead of assuming `<root>/tools`.

### Broker protocol gaps (B4-11)

QoS 2 PUBLISH retransmissions are de-duplicated with a bounded, TTL'd
per-client in-flight id set; a non-CONNECT packet before CONNECT drops
the connection; Will topics containing `+`/`#` (or empty) are rejected.

### DeepSeek V4.1 Flash (E4-1 + operator requirement)

`deepseek` is registered first in `PROVIDERS` with `PROVIDER_PREFERENCE =
deepseek > synthetic > cerebras`. Model `deepseek-flash` (V4.1 Flash,
released 2026-09-10), `reasoning_effort` low|high|max with the provider's
own folding table, OpenAI-compatible endpoint `https://api.deepseek.com/v1`.
Legacy ids (`deepseek-v4-flash`, `deepseek-v4-pro`) and friendly aliases
route to V4.1 Flash. `Settings#reconcile_provider_preference` migrates a
stale `runes.db` at boot, so the live tree now resolves to
`deepseek / deepseek-flash / reasoning_effort: high`. `RUNES_MAX_TOKENS`
was added, and `usage`/`finish_reason` are surfaced and journalled.
Connection-level errors (`ECONNRESET`, `EPIPE`, `SocketError`, …) are now
retried, not just timeouts.

### Tests are hermetic and offline (B4-1/B4-13/E4-2/E4-10)

- `test/test_helper.rb` sets `RUNES_ROOT` to a throwaway tree and deletes
  every provider key from `ENV` at load: no test can read `config/.env`
  or write into the developer's checkout (the journal is no longer
  appended to during `rake test`).
- The live network smoke test was **removed**. `LLMClient` gained an
  injectable `transport:`; tests drive the entire call path with a
  `DupTransport` returning real `Net::HTTPResponse` objects with canned
  bodies — content, native tool_calls, `finish_reason=length`, malformed
  tool args, every error-body shape, and retry behaviour, all with no key
  and no network. `RUNES_RETRY_BACKOFF_S` lets retry paths run without
  sleeping.
- `popen_script` no longer closes a pipe while its reader thread is
  blocked in `read` (the source of the order-dependent
  "stream closed in another thread" error); it kills the process group
  and joins the readers first.
- Suite result: **258 runs / 1059 assertions / 0 failures / 0 errors /
  0 skips** (previously 202/532 with 1 non-deterministic failure and 1
  live-call skip).

### Docs & repo hygiene (B4-12/E4-13)

`.gitignore` added (the live `config/.env`, `runes.db`, `log/`,
`workspace/`, `ruby.wasm`, generated `docs/epics|missions`) — the tree
previously had no ignore file while holding a live API key and a
`git init` suggestion in the runbook. README and STATE were rewritten
for the new provider order, the RPC/`run_command` security model, the
`/started` topics, the new env vars and the real test counts.

### One more hermeticity bug found while verifying

Re-creation of `log/journal.jsonl` after the suite kept disappearing. A
per-file bisect (`for f in test/*_test.rb; do sentinel; run; check; done`)
traced it to `test/cli_tools_test.rb`: two replay tests wrote a fixture
journal to `<project>/log/journal.jsonl` — the developer's real audit
trail — and deleted it in `ensure`. `bin/runes-replay` also hardcoded the
project root, so it could not be pointed elsewhere. Fix:
`bin/runes-replay` now honours `RUNES_ROOT` (like `Settings`), and the
tests write the fixture under their own tmp root and pass `RUNES_ROOT` to
the subprocess. A sentinel journal now survives a full suite run.
(`bin/runes` also uses `Settings.default_root` instead of the frozen
`Settings::ROOT` constant for its default root.)

### Live validation (DeepSeek V4.1 Flash)

- Direct call: `deepseek / deepseek-flash`, 1.5 s, `reasoning_tokens`
  present, `finish_reason=stop`.
- `demo/hello_world_live.rb` → **ALL CHECKS PASSED (3.1 s)**: prompt →
  plan → `write_file` ×2 → `run_command` (generated minitest green) →
  correlated reply → journal entry keyed by the request id.
- This validation paid for itself twice:
  1. It exposed **B4-14** — `tool_schemas` emitted the builtin schemas
     twice (the `tools/` directory ships manifests for `write_file`,
     `read_file`, `run_command` too), and DeepSeek rejects duplicates with
     `HTTP 400: Tool names must be unique`. Synthetic had silently
     tolerated it, which is why earlier live demos never caught it. Fixed
     in `tool_schemas` and defensively in `LLMClient.builtin_schemas`.
  2. It showed DeepSeek plans **iteratively**: given the demo prompt it
     returned only the two `write_file` calls and stopped (raw
     `finish_reason=tool_calls`, empty content), because a real agent loop
     would feed tool results back. The tool-mode system prompt now states
     explicitly that it is a single turn, that every requested step
     (including the `run_command`/verification) must be emitted in one
     response, and that omitting a step is wrong — measured: 2 calls
     before, 3 (write, write, run) after. A bounded tool-result feedback
     loop remains the robust fix and is recorded in STATE's known gaps.

---

## Phase 15 — Runes Observatory (Rails 8.1 / Ruby 4)

Goal (operator request): a web app to **view the interaction between all
running agents and the payloads sent over MQTT** — running *and* ended
agents, and, per agent, its history.

### Shape

A new app at `runes_observer/`, generated with `rails new` on Rails
8.1.3.1 / Ruby 4.0.4 (importmap + Stimulus + Propshaft + SQLite; Kamal,
Docker, CI, RuboCop, Solid*, Action Cable, Active Storage and Action
Mailer skipped to keep the surface small).

```
MQTT broker ──runes/#──▶ MqttIngest ──▶ PacketClassifier ──▶ PacketRecorder ──▶ SQLite
(mosquitto/embedded)   (bin/runes-ingest)   (topic → kind/agent/request)          │
                                                                                 ▼
                     browser ◀── Stimulus /feed poller ◀── PacketsController ──▶ views
```

- **`PacketClassifier`** — pure topic grammar → `kind`
  (card/status/task/task_response/prompt/claim/started/progress/response/
  response_global/session_claim/session_started/tool_*/journal/other) plus
  `agent_id`, `request_id`, `lease_id`, `event`, `tool`. Unknown topics are
  stored as `other`, never dropped.
- **`PacketRecorder`** — the single write path (live ingest *and* the demo
  seeder go through it, so the UI cannot show rows the recorder would not
  have produced). It also keeps the agent row current: card metadata,
  online/offline from the status topic (LWT), last-seen and packet count,
  with "who executed this request" inferred from the claim/started packets
  and memoized in-process so a progress burst does not re-query per packet.
  Payloads over 256 KiB are truncated with a flag; retention prunes by age
  and a hard row cap.
- **`MqttIngest` / `bin/runes-ingest`** — subscribes to `runes/#`,
  reconnects with exponential backoff, and publishes its own health into a
  singleton `ingest_statuses` row so the web process can show whether the
  bus is actually being watched.
- **Web** — dashboard (running / ended / stale agents, live feed, ingest
  health), agent page (card, interactions grouped by request/lease with the
  full claim → started → progress → response timeline, packet history),
  packet log with filters, and one page per interaction. Live updates are a
  Stimulus poller against `GET /feed?after_id=…` which returns rows
  rendered by the *same partial* as the first page; SQLite WAL lets the
  ingest write while the UI reads, so no cable/queue infrastructure is
  needed between the two Rails processes.

### Verification

- `bin/rails test` → **56 runs, 307 assertions, 0 failures, 0 errors**
  (classifier table, recorder bookkeeping/attribution/retention/quota, the
  singleton ingest status, the demo seeder, all four controllers including
  the JSON feed, and an integration walk from recorded packet → dashboard →
  agent → interaction → filtered log).
- Live end to end: a mosquitto broker on 1883 + `bin/runes-ingest`; a
  publisher script (`runes_observer/tmp/publish_live.rb`) sent a card,
  status, prompt, claim/started, progress, response, journal entry, session
  lease and a tool RPC — the observatory created the agent and all 18
  packets, and the dashboard, agent page, interaction page and `/feed`
  all rendered them.
- `bin/rails runes:demo` seeds the same shape offline for instant browsing.

### Notes / hard-won details

- **json 3.0.0 breaks Rails 8.1**: `JSON.parse`'s signature changed
  (options became keyword-only) while `ActiveSupport::JSON.decode` still
  calls `JSON.parse(source, options)`, so any encrypted payload — flash
  messages, cookies — died with `wrong number of arguments (given 2,
  expected 1)`. The app pins `json ~> 2.21` (2.21.2 is installed here).
- The machine's gem home is outside the writable sandbox, so the app's
  lockfile was resolved against the *installed* gems (`bundle lock --local`)
  rather than installing a full bundle; `selenium-webdriver` was dropped
  because it is not installed and system tests are not used.
- The observer is deliberately read-only; a "send prompt" control would be
  the natural next step (it would need the tool-RPC/secret model from
  Phase 14).

---

## Phase 16 — 0.3.0: transport-agnostic fabric, A2A, MCP, identity

Driver: the strategic review (now `STRATEGY.md`). Four conclusions became
work items: (1) MQTT is a fine fabric but a bad place for coordination
primitives, (2) the claim/lease protocol re-implemented mechanisms MQTT 5
now standardises, (3) other ecosystems will only talk to Runes through A2A
and MCP, and (4) the durable value is the guard + verify/resume loop +
observatory, not the transport.

### P0.1 — `Runes::Transport` (the seam)

`lib/runes/transport/` with a documented contract (`base.rb`), a
process-local hub (`in_process.rb`, the reference implementation: topic
matching, retained messages, **native shared groups**), an MQTT 3.1.1
adapter (`mqtt311.rb`, maximum compatibility, groups unsupported by
honest refusal) and a hand-rolled **MQTT 5** adapter (`mqtt5.rb`, ~900
lines including a full property codec: shared subscriptions, Response
Topic / Correlation Data / User Property, CONNACK capability probing).
`Transport.build(kind:)` selects; `Transport.auto` probes. The dispatcher
now takes `transport:` and no longer owns a receive loop — handlers run on
transport threads and enqueue to the worker pool.

### P0.2 — the consensus is gone (−250 lines)

Deleted: claim/lease, `@claims`, `@started`, `begin_execution?`,
`record_claim`, `announce_and_resolve`, the session-lease ids, the claim
and started topic patterns. Work distribution is now
`subscribe(PROMPT_TOPIC, group: "runes-prompts")`, i.e. MQTT 5
`$share/runes-prompts/runes/prompts`; the broker picks one member.
`test/fabric_test.rb` proves a prompt is planned **exactly once** with two
agents in one group. On MQTT 3.1.1 the agent either fails
(`RUNES_REQUIRE_SHARED_SUBSCRIPTIONS=1`) or runs as the single consumer
with a loud warning — it never silently duplicates work.

### P0.3 — A2A-over-MQTT

`lib/runes/a2a.rb` + `a2a/{card,task}.rb`: builders/parsers for the
standard Agent Card (`protocolVersion`, `preferredTransport`, `skills`,
`capabilities`) with harness facts under `x-runes`; discovery at
`$a2a/v1/discovery/<org>/<unit>/<agent_id>` (retained) with an
`a2a-status` user property, tasks at `$a2a/v1/tasks/...` answered via
Response Topic/Correlation Data. The legacy `runes/agents/<id>/card` is
still published verbatim so the TUI and the observatory keep working.
Peers discovered from the wildcard subscription are kept in a bounded
registry (`#peers`).

### P1.4 — MCP, both directions

`lib/runes/mcp/` (protocol, stdio server, subprocess client, tool
provider) + `bin/runes-mcp`, which serves the builtin + manifest tools
over stdio with the capability guard enforced per call and no need for a
broker, a database or WASM. 18 hermetic tests; the client spawns servers
and correlates JSON-RPC by id with a stderr drain thread.

### P1.5 — identity, signatures, ACLs

`lib/runes/security/` (Ed25519 identity, canonical signed envelopes, a
fail-closed trust store, redacted credentials) + `bin/runes-acl`, which
generates a mosquitto ACL file per agent with no catch-all allow.
Wired into the dispatcher: with `RUNES_REQUIRE_SIGNATURES=1` inbound
envelopes must verify against a trusted key or they are refused (and
answered) before the planner ever sees them, and outbound delegation
envelopes are signed. 48 security tests.

### P1.6 — dispatcher split

`lib/runes/agent/{fabric,journal,session_store}.rb`: the transport-facing
subscriptions, publishing, A2A and delegation moved to `Fabric`; the
durable journal to `Journal`; the goal-session store to `SessionStore`.
Dispatcher keeps the pipeline (lifecycle, workers, envelope parsing,
build/goal/plan/mission modes, tool execution, path/command safety).
Move-only: no behaviour change, constants referenced by tests stay
reachable.

### P2 — packaging and positioning

`runes.gemspec` (explicit allow-list, `wasmtime` optional, executables
from `bin/`), `lib/runes.rb` entry point, `lib/runes/llm.rb` adapter
registry with a lazy `ruby_llm` adapter (ruby_llm is deliberately not a
dependency), `GEM_PACKAGING.md`, and `STRATEGY.md` — the niche ("sandboxed,
auditable agent execution for local-first fleets"), the moat, the audience
mapping and the honest risks. README repositioned to match.

### Verification

- `test/transport_test.rb` — the contract across the in-process hub and
  MQTT 3.1.1 (fan-out, retained, group exactly-once round-robin, capability
  refusal, properties where supported).
- `test/mqtt5_codec_test.rb` — 33 hermetic codec tests; and the manual
  `tmp/verify_mqtt5_live.rb` against mosquitto 2.1.2 proved **shared
  subscriptions deliver exactly once per group** (13/12 split at N=25,
  100/100 at N=200, no dupes, no losses) plus Response Topic/Correlation
  Data round trips, retained delivery and keepalive.
- `test/fabric_test.rb` — exactly-once at the dispatcher level, A2A card
  publication + peer discovery, A2A task execution, unsigned rejection and
  signed acceptance.
- `test/security_test.rb` (48), `test/mcp_test.rb` (18),
  `test/packaging_test.rb` (11).
- Observer: `$a2a` classification + card normalization; the ingest now also
  subscribes `$a2a/#` (wildcards never match `$`-prefixed topics — found by
  the observer workstream).
- Bugs found *by* this work: `A2A.agent_id_from_discovery` was off by one
  (returned the unit instead of the agent id), `task_wildcard` had one
  wildcard too many so A2A tasks never arrived, and MQTT 3.1.1's
  capability check ran after the connected check (so "can you do groups?"
  raised the wrong error).

---

## Phase 17 — Roast-compatible Runes (`:rune` plugins)

Driver: a direct request to adopt Shopify **Roast**'s cog system, renamed
with a runic theme — `chat`, `agent`, `ruby`, `cmd`, `map`, `repeat`,
`call` — and, more importantly, to make the *unit* of extension the same
thing Runes is already built from: a plugin.

### The idea, and why it fits

Roast's cogs are already plugins in every way that matters: a named
registry, a declared input/output contract, a per-cog config object, and
a step body that receives a coerced input and returns an output object.
What Roast lacks is a *uniform* notion of what a unit of work is, plus
the operational furniture around it — authorisation, journalling,
resumption, observability. Runes has exactly that furniture and no DSL.

So the unification is: **a Rune is a `Runes::Plugin` of kind `:rune`.**

```ruby
class Runes::Plugins::Cmd < Runes::Rune   # < Runes::Plugin
  rune :cmd                              # register as kind :rune
  # Input/Output/Config + call(input, chunk) => output
end
```

`Runes::Plugin.names(kind: :rune)` therefore lists the rune vocabulary
the same way it lists any other plugin kind, and the workflow DSL's verbs
are thin, name-identical wrappers over the registry. Two consequences
worth stating plainly:

1. **A third party can add a verb without touching the engine** — drop a
   class in, register it, and `myverb(:name) { ... }` exists.
2. **Every rune inherits the harness's operational envelope**: a Rune
   invoked from a workflow can be journalled, replayed, capability-checked
   and shown in the observatory, because it is a plugin and not a special
   case.

### Compatibility contract

The deliverable is DSL-level compatibility: a Roast workflow file must
run unmodified. That fixes a number of behaviours that are easy to get
wrong, and all of them are treated as spec rather than preference:

- `instance_eval` of a plain `.rb` against the workflow; only `config`,
  `execute(scope = nil, &blk)` and `use` exist at the top level.
- Positional step names, anonymous fallback to `SecureRandom.uuid.to_sym`,
  and blocks invoked as `input_context.instance_exec(input, scope_value,
  scope_index, &blk)` — so `self` inside a step is the cog input context
  and `cmd!(:recent_changes)` is a method call, not a variable.
- The `X` / `X!` / `X?` accessor triple, `outputs` / `outputs!`, and the
  `from` / `collect` / `reduce` combinators.
- Control flow via `skip!` / `fail!` / `next!` / `break!`.
- Config scoping `nil` → `:name` → `/regexp/` → name, merged in that
  precedence order.
- The readers each cog actually exposes, including the surprising ones:
  `cmd` has `out`/`err`/`status` but **no** `success?`; `chat` has
  `response`; `agent` has `response`/`session`/`stats`; `map` has
  `iteration(i)`/`iteration?`; `repeat` has `value`/`results`; `call` is
  opaque and only reachable through `from(...)`.
- Roast's **absences** too: no `respond`/`finalize`/`inputs`, no
  `parallel:`/`on_error:`/`timeout:`/`skip:` step kwargs, no `.roast/`
  config file, no built-in retry. Matching the absences is what keeps an
  unmodified file running.

### Deliberate deviations

Three, each with a reason:

1. **No `async` gem** — `parallel(n)` on `map` and `repeat` uses Ruby
   `Thread`s. The dependency would be the only one in the gem whose
   purpose is to make concurrency look synchronous; threads are already
   what the dispatcher's worker pool uses.
2. **No `ruby_llm` dependency for `chat`** — the chat rune routes through
   a backend seam that defaults to the harness's existing LLM client
   (`RUNES_LLM_ADAPTER=ruby_llm` opts in when the gem is present). Chat
   was already solved in this codebase; re-solving it inside a cog would
   duplicate the provider table, key handling and demo transport.
3. **`cmd` and `agent` run under Runes' sandbox and path rules** —
   Roast shells out freely. Here the command runner takes an argv (no
   shell), and the guard can refuse a rune the same way it refuses a tool
   call.

### Landed so far

- `lib/runes/plugin.rb` — `Runes::Plugin` registry: `plugin :name,
  kind:`, `register`/`fetch`/`[]`/`registered?`/`all(kind:)`/`names(kind:)`
  `/reset!`, instance `context`/`options`/`execute`/`describe`.
- `docs/WORKFLOWS.md` — the Rune-as-`:rune`-plugin concept, an example
  plugin, the rune table, the Roast example, compatibility and
  matched-vs-deviations tables, and the rationale above.
- `lib/runes/agent/{fabric,journal,session_store}.rb` — the dispatcher
  reduced from 1968 to 1545 lines with the fabric, journal and session
  bookkeeping extracted as behaviour-neutral moves (A/B verified: the
  same 373 runs / 1694 assertions against both versions). The workflow
  engine needs a dispatcher small enough to reason about.

### The engine

`lib/runes/workflow.rb` is the entry point; `lib/runes/rune.rb` defines
`Runes::Rune` (aliased to `Runes::Cog`, so `Runes::Cog::Input` and
`Cog::Input::InvalidInputError` resolve). The engine proper is
`lib/runes/workflow/` (~1,500 lines): `workflow.rb` (`instance_eval` of the
file against the workflow object, `config`/`execute`/`use`), `cog.rb`
(Params/Config/Input/Output and the `WithText`/`WithJson`/`WithNumber`
mixins), `cog_input_context.rb` (the `self` inside a step block: the
`X`/`X!`/`X?` accessors, `outputs`, `from`/`collect`/`reduce`,
`skip!`/`fail!`/`next!`/`break!`), `config_manager.rb` (scoping and merge
precedence), `execution_manager.rb` (scope execution, output resolution),
`task.rb` (a thread-backed `TaskGroup`), `system_rune.rb` (the `run:`
parameter for call/map/repeat) and `workflow_params.rb`. Nothing here needs
the `async` gem.

`lib/runes/command_runner.rb` is the one process boundary: an argv command,
`pgroup`, a timeout, optional line handlers and separate capture.

### The seven runes

Each is a `kind: :rune` plugin under `lib/runes/plugins/`, so
`Runes::Plugin.names(kind: :rune) == [:agent, :call, :chat, :cmd, :map,
:repeat, :ruby]` and `Runes::Plugin[:cmd] == Runes::Plugins::Cmd`:

| Verb | Class | Lines | Notes |
| --- | --- | --- | --- |
| `ruby` | `Plugins::Ruby` | 85 | the value *is* the output; `[]`/`call`/`method_missing` delegate to it |
| `cmd` | `Plugins::Cmd` | 157 | `fail_on_error?` default on; `show_stdout!`/`show_stderr!`/`quiet!` |
| `chat` | `Plugins::Chat` | 402 | the full Roast config surface + `Session`; backend seam |
| `agent` | `Plugins::Agent` | 693 | `:pi`/`:claude` argv built exactly; prompt on stdin; `Stats`/`Usage` |
| `call` | `Plugins::Call` | 68 | opaque output, read with `from(...)`; requires `run:` |
| `map` | `Plugins::Map` | 176 | serial by default, `parallel(n)` on threads |
| `repeat` | `Plugins::Repeat` | 97 | each `final_output` feeds the next `scope_value` |

Three seams keep the suite hermetic: `Cmd.command_runner=`,
`Agent.provider_factory=`/`command_runner=` and `Chat.backend=`. No test
calls a provider or spawns a real agent CLI.

### The CLI

`bin/runes-workflow execute FILE [targets...] [-- key=value flag]`, a bare
`runes-workflow FILE`, plus `version` and `help`. Options before `--` are
the runner's (`-p/--print`, `-q/--quiet`); everything after belongs to the
workflow. It prints the final output by default, exits 2 when no file is
given and 1 with the error on stderr when a rune fails.

### Compatibility, proven rather than asserted

`examples/analyze_codebase.rb` is the **Roast README example** — its
`execute` block is byte-for-byte Roast's, and only a comment header was
added — and it is committed as a shipped example. `test/roast_compatibility_test.rb`
reads that file (so the docs cannot drift from what is tested), runs it
with the three seams faked, and asserts the cross-step wiring that the
example exists to demonstrate: the `cmd!(:recent_changes).lines` array
reaching the agent prompt, `agent!(:review).response` reaching the chat
prompt, `chat!(:summary).response` readable at the end, and no network.
The same file also pins the exact argv both agent providers build, the chat
config surface and the `call`/`map`/`repeat` combinators.

### What changed while implementing this

Two flaws were found by using the feature rather than by testing it:

1. **A Hash is not a `cmd` input.** The first draft of the README example
   (and of this file) wrote `cmd(:x) { { command: "git", args: [...] } }`.
   That is not Roast's surface — Roast takes a String or an argv Array — so
   the rune correctly failed with `'command' is required`, which says
   nothing about the actual mistake. Both examples were rewritten to the
   Roast form, and `Cmd::Input#coerce` now answers a Hash with a message
   naming the right two shapes. A test asserts the message.
2. **Two documentation claims were false.** `docs/WORKFLOWS.md` claimed
   `cmd`/`agent` "inherit the harness's confinement rules
   (`RUNES_CMD_ALLOWLIST`, path containment)"; they do not — those live on
   the dispatcher/MCP tool path. And `field :name` was shown without its
   required default (`field(key, default, &validator)`) on an `Input`, while
   `field` is only defined on `Config`. The docs now state the guard gap
   explicitly (STATE.md lists it as gap 1) and the extension example is a
   class that `test/plugin_test.rb` actually runs.

### Verification

- `bundle exec rake test` — **455 runs, 2083 assertions, 0 failures, 0
  errors, 0 skips** (was 373/1694 before this phase).
- `cd runes_observer && bin/rails test` — **61 runs, 348 assertions, 0
  failures** (unaffected).
- `gem build runes.gemspec` — builds 0.3.0, 77 files; `runes-acl` (on disk
  since Phase 16 but absent from the gemspec) and `runes-workflow` are now
  both in `spec.executables`, and `test/packaging_test.rb` asserts that
  `bin/` and the gemspec executable list agree.
- New tests: `test/workflow_engine_test.rb` (42), `test/roast_compatibility_test.rb`
  (14), `test/workflow_cli_test.rb` (12), `test/plugin_test.rb` (14).

### Known deviations (deliberate, documented)

Threads instead of `async` (a running thread cannot be cancelled, so
`break!` only stops iterations that have not started); no `Event`/monitor
system (display goes to `$stdout`); no `ruby_llm` dependency (`chat` routes
through Runes' own provider router; `RUNES_LLM_ADAPTER=ruby_llm` opts in);
runes do not consult the capability guard (`docs/WORKFLOWS.md` has the
detail, STATE.md tracks it as the next step).

---

## Phase 18 — implementing the round-5 audit (`doc5.md`)

Driver: `doc5.md`, the round-5 audit — 52 findings (3 critical, 15 high, 24
medium, 8 low, 2 medium-low) across the harness, the observatory and the test
suite. This phase implements the findings in the audit's own priority order.
Four workstreams ran in parallel with disjoint file ownership (lead:
transport/guard/topics/MCP/A2A; agents: workflow, security/dispatch,
observatory).

### The three criticals

**T5-1 — the transport could not recover from a lost connection.** `Mqtt5`
now owns a reconnect loop: `read_loop`/`consume` hand a dead socket to
`reconnect!`, which backs off 1 s → 30 s (jittered via the cap), re-sends
CONNECT through the shared `open_and_handshake!`, and re-SUBSCRIBEs every live
subscription (fire-and-forget, because waiting for SUBACK on the reader thread
would deadlock against the thing that delivers it). A `health`/`on_health`
hook and a `reconnects` counter make it observable. Proven by
`test/transport_lifecycle_test.rb`: drop the socket → reconnect → the filter is
SUBSCRIBEd twice → a message published *after* the reconnect reaches the
subscriber.

**W5-1 — a workflow argument was remote code execution.** `CommandRunner`
splits a String command with `Shellwords.split`, never hands a one-element argv
to `Open3` (which is what made Ruby choose `/bin/sh`), and refuses a token
containing a shell metacharacter with a new `CommandRunner::ShellSyntaxError`;
`shell: true` / `Cmd::Config#shell!` is the explicit opt-in. The audit's exact
reproduction now exits 1 with no file created, and the shipped Roast example
(`"git diff --name-only HEAD~5..HEAD"`) still runs.

**O5-1 — one bad byte wedged ingest forever.** `PacketRecorder` force-encodes
payloads to UTF-8 and scrubs them (recording `scrubbed`), `MqttIngest` isolates
each message behind a rescue that counts a drop and keeps the connection, and
every `IngestStatus` writer is now non-raising. Measured: connect attempts 4 →
1 in 8 s, one retained card stored once instead of four times.

### Also fixed

- **Security:** one signature-admission gate (`Fabric#admitted_payload`) now
  covers the broadcast, delegated *and* A2A paths, with `handle_prompt`
  refusing any envelope that did not come through it; a shared
  `Runes::Security::CommandPolicy` (used by both the dispatcher and
  `bin/runes-mcp`) with a default non-interpreter allowlist, interpreter
  refusal, attached-option path splitting and unclassifiable-token refusal —
  the round-4 `run_command` escape is closed (verified: no file outside the
  workspace); `Guard` loads the policy *first*, so a corrupt policy fails
  closed instead of silently keeping the builtin allow-all; tool-RPC gained
  `{ts, nonce, MAC}` freshness with a bounded nonce cache and an ACL switch to
  narrow who may read the secret-bearing topic; reply topics are validated
  (`runes/` prefix, no wildcards/`$`); NUL paths are rejected and always
  answered; agent ids are validated at dispatcher construction.
- **Transport:** ONE topic matcher (the in-process hub, the broker and the
  guard all call `TopicFilter`, now spec-correct: a leading wildcard never
  matches a `$`-topic, a mid-filter `#` is invalid and matches nothing, empty
  levels are preserved); PINGRESP is tracked so a half-open peer is dropped;
  writes have a deadline; PUBACK reason codes survive (`publish!` raises on
  ≥ 0x80); QoS 3 is rejected as malformed; `require "json"` in the transport
  base; group names validated; the MCP fixture moved out of gitignored `tmp/`;
  MCP `Client#start` is thread-safe and its reads are bounded; A2A task ids are
  validated and its wildcard defaults are no longer mangled.
- **Workflow:** `chat` validates its config *before* the request and threads
  provider/model/temperature through a `Chat::RouterClient`; `run!`'s `ensure`
  no longer swallows the original exception; `map parallel(n)` uses a
  fixed-size worker pool (800 items at `parallel(4)`: 807 threads → 10); async
  failures surface in completion order; `cmd`/`agent` take a `timeout` and
  `repeat` is bounded (10 000 iterations or a workflow deadline, both
  overridable); anonymous runes no longer grow the config manager; and
  `Plugin.reset!` is atomic.
- **Observatory:** the dead claim/lease vocabulary is gone end to end (three
  migrations drop the column and remap the kinds) and **agent attribution is
  backfilled** — a request's rows are attributed when the journal reveals the
  executor (1/4 rows → 5/5); list views ship 2 KiB summaries with full payloads
  on demand (`/feed` 50.2 MiB → 0.60 MiB); `/agents/:id` paginates (48.9 MiB /
  3.8 s → 1.12 MiB / 170 ms); retained replays no longer resurrect a dead
  agent; retained duplicates are deduped; `RUNES_OBSERVER_MAX_PACKETS<=0` no
  longer deletes the table; search escapes LIKE metacharacters; a silently
  dead ingest now reports `dead`.

### Verification

- Parent suite **527 runs / 2419 assertions / 0 failures / 0 errors / 0 skips**
  (was 455 / 2083); observatory **89 runs / 454 assertions / 0 failures**
  (was 61 / 348), re-run against a database built from `db/schema.rb` alone to
  prove a clean clone works.
- Every doc5.md reproduction named above was re-run by the lead, not taken on
  the fixer's word — including the two I insisted on checking personally
  (S5-1's gate covering all three inbound paths, and S5-2's escape now
  reporting "path escapes the workspace" with no file written).

### What this phase did NOT fix (deliberate, from the audit's own list)

- **Envelope replay** (as opposed to tool-RPC replay) is still open — signed
  envelopes carry no timestamp/nonce; stated in `docs/SECURITY.md` §8.
- **A2A peer-card spoofing** remains possible (the id is validated, but a
  retained card from any publisher is still accepted; discovery-only impact).
- **Token scanning is not a sandbox**: an explicitly allowlisted interpreter
  can still escape. Real confinement needs `sandbox-exec`/`bwrap`.
- **W5-6/W5-7/W5-8/W5-9** (Bundler env thread-safety, joining runes on abort,
  `async` after `stop`, the agent rune's `working_directory`) were not in the
  implemented set.
- **Retention is still ingest-driven** — no cron backstop, and agents are not
  pruned.
- The default `run_command` allowlist is deliberately small, so `git`, `make`
  and `curl` now need `RUNES_CMD_ALLOWLIST`: an intended deny-by-default, but a
  real behaviour change for planner demos.

---

## Phase 19 — closing the audit's leftovers, and version control

Driver: the residues `doc5.md` listed as *deliberately not fixed* in Phase 18,
plus two process gaps the audit exposed.

### Version control

The repository had no history at all, so a 52-finding audit and four parallel
workstreams were only reconstructable from this log. It is now a git repository
with one commit per logical batch. `config/.env`, `runes_observer/config/master.key`,
the SQLite databases and `log/` are ignored, and the index was verified to
contain **none** of them (and not the live key's value) before the first commit
— the S4-3 exposure this project has been one `git init` away from since round 4.

### The leftovers

- **Signed-envelope replay (S5-4 residual).** The signature proved *who* sent a
  payload, not *when*: a captured signed envelope replayed forever.
  `Envelope.sign(fresh: true)` now puts a `ts`/`nonce` pair *inside* the signed
  payload, so altering or stripping them breaks the signature, and `verify!`
  enforces a clock window and consumes the nonce through a bounded cache.
  `Fabric` signs fresh and verifies with a process-wide guard;
  `RUNES_REQUIRE_FRESHNESS=1` additionally refuses envelopes carrying no
  freshness, so an older peer still interoperates by default. The nonce cache
  moved out of `RPCAuth` into `Runes::Security::NonceCache` so both paths share
  one implementation, and the audit's missing **signature-forgery** negative
  test (sign with key B while claiming trusted kid A) is pinned as
  `:bad_signature`.
- **MQTT 3.1.1 reconnect (T5-1's other half).** Worse than the MQTT 5 form: the
  `mqtt` gem's read thread raises on a dropped socket and stops, and
  `MQTT::Client#get` then blocks forever on an empty queue — so the adapter went
  silent while still reporting `connected? == true`, and no reconnect could
  ever fire. It now consumes the gem's queue with a timeout, notices the dead
  reader within 0.5 s, and reconnects with backoff, re-sending every
  subscription. The embedded broker gained `disconnect_clients!` and `stop` so a
  broker-side drop is testable at all.
- **W5-6..W5-9.** The agent rune now passes its configured `working_directory` to
  the child (it was accepted and ignored); `Bundler.with_unbundled_env` is
  serialised, because it mutates the *process* environment and concurrent runes
  could corrupt it; `TaskGroup#async` no longer starts a task after `stop`; and
  `stop` reports stragglers while a new `drain(timeout:)` joins them — it
  deliberately does not block, because joining would make a fast failure wait
  for a slow sibling and undo W5-5.
- **Retention backstop (O5-6 residual).** Pruning ran only from the packet path,
  so an idle broker meant nothing was ever pruned, and agent rows were never
  pruned at all. The ingest now owns a pruner thread independent of traffic
  (`RUNES_OBSERVER_PRUNE_INTERVAL_S`, default 15 min) and `prune!` also drops
  agents that are past `RUNES_OBSERVER_AGENT_RETENTION_DAYS` and have no packets
  left.

### Verification

- Parent **541 runs / 2460 assertions / 0 failures**; observatory **90 runs /
  455 assertions / 0 failures**.
- Live against mosquitto 2.1.2: the MQTT 5 proof still passes after the
  lifecycle rewrite, and a new script (`tmp/verify_reconnect_live.rb`) yanks the
  socket out from under a real connection and proves the adapter reconnects,
  re-subscribes and receives traffic published *after* the drop — the audit's
  own demonstration, in reverse.
- The 3.1.1 reconnect is covered in-suite by killing the gem's reader (the exact
  condition the adapter polls for). Closing the socket under that reader raises
  from the gem's own thread, which the harness attributes to whichever test is
  running — a limitation of `mqtt` 0.7 documented in the test rather than hidden.
- Two order-dependent assertions were found and fixed while doing this: they
  passed only when an earlier test had leaked a `TaskGroup` into the thread-local
  (`assert_same nil` trips Minitest's style guard) — the same class as D5-2.

### Still open

`O0.1` (observatory ingest through `Runes::Transport`), `E5-2` (a
publisher↔observer topic contract test), `E5-6` (guard-aware runes) and `O1.1`
(workflow telemetry + run console) remain from `docs/OBSERVATORY_ROADMAP.md`;
A2A peer-card spoofing and "token scanning is not a sandbox" are untouched.

---

## Phase 20 — the observatory becomes a fleet console (O1.1)

Driver: the newest code in the project was invisible. A Roast-compatible
workflow runs in-process and published nothing, so the observatory could only
ever show packets — never the runs that produce them.

### The engine seam

`lib/runes/telemetry.rb` adds a best-effort event stream at run and step
boundaries: `run_started`, `step_started`, `step_finished`, `run_finished`,
each carrying the run id, rune, name, scope, run-wide step index, status,
duration, output and error. `Runes::Telemetry.sink` is any callable, so a
library user pays nothing when it is unset; `TransportSink` publishes the events
on `runes/workflows/<run_id>/<kind>` for anything watching the fabric. A raising
sink cannot fail a run (tested), and long output is truncated with a marker.

The context is threaded through the `CogInputContext` — every rune already
receives one — so no call site had to learn about telemetry, and nested scopes
(call/map/repeat) share the run's id.

### The console

`bin/runes-workflow` gained `RUNES_TELEMETRY=mqtt|auto|1`; the observer gained
`workflow_runs`/`workflow_steps` (two migrations), a classifier branch for
`runes/workflows/#`, a `WorkflowRunProjector` that folds the four event kinds
into rows (idempotent, and it creates a run on demand if the observer started
mid-run), plus:

- **`/runs`** — every run with status, step count, and a duration bar scaled
  across the page so a slow run stands out without reading numbers.
- **`/runs/:id`** — the timeline: one row per step with a bar positioned by its
  offset and scaled to the run, then a card per step carrying scope, output and
  error, and finally the packets that carry that run id.
- A **Runs** nav link and a "Workflow runs" dashboard panel.

### Verification

Parent **548 runs / 2493 assertions / 0 failures**; observatory **103 runs /
530 assertions / 0 failures**. The projection test runs the *real* engine and
feeds its events through the same recorder the ingest uses, so the two halves
cannot drift. And the whole path was driven over a real broker: the CLI
published 8 telemetry events to mosquitto 2.1.2, the observer's recorder
ingested them, and the run appeared with three correctly ordered steps
(`ruby(greeting) 0.2ms`, `cmd(echo) 24.7ms`, `ruby(check) 0.3ms`).

Still open from the roadmap: `O0.1` (ingest via `Runes::Transport`), `E5-2`
(topic contract test), `E5-6` (guard-aware runes), and the further views
(topology, trace waterfall).

---

## Phase 21 — the rest of the fleet console: topology, waterfall, traffic

Driver: the observatory could show runs, agents and packets, but nothing that
answers *how is this fleet shaped* or *where did this interaction spend its
time*. Both answers are derivable from packets already stored, so this phase is
view work with no new ingest.

### `/topology` — the fleet as a graph

`FleetTopology` derives nodes and edges from stored packets, deliberately
conservatively: an **edge** exists only where the harness states both ends
(a delegation packet's topic names the target and its payload's `from` names the
delegator), and a `task_response` for the same request id completes that edge
with its measured latency. An A2A task whose sender is not in the payload is
counted as **inbound work on the target node, never drawn as an edge** —
inventing an arrow from a topic that only names the receiver would be a lie with
a nice picture. Node degree, executed work, tool counts and errors come from
cards, progress and tool packets.

`FleetTopology::Layout` computes a **deterministic** circular layout in Ruby and
the view renders it as inline SVG: no JavaScript, no physics, and the same fleet
always draws the same picture (so a screenshot, a test and a second look agree).
Wire width scales with task volume, colour with failure rate; nodes are sized by
activity and coloured by state. A table underneath carries the numbers (tasks,
replies, failed, average and max latency, last seen), and an empty fleet
explains how to produce traffic instead of drawing blank space.

### The interaction page's waterfall

`InteractionTimeline` turns an interaction into spans. A packet on this bus is an
*instant*, so the informative quantity is the **gap before it**: a 30-second
pause between `started` and the first `progress` is the planner call, and it now
looks like 30 seconds. Each bar is a gap, positioned by offset and scaled to the
whole interaction; the largest gap is named when it is at least 40% of the total
("dominated by progress · plan_ready"), and packet arrivals are drawn as ticks.
The 40% threshold was chosen after the first attempt called a 33% gap dominant in
a four-packet interaction — noise dressed up as insight.

### The dashboard

A 30-minute packets-per-minute sparkline (a quiet minute is a zero-height bar,
because "the fleet went silent" is information) and a "what it is carrying" mix
of the top kinds over the last hour with counts and shares.

### Verification

Observatory **124 runs / 629 assertions / 0 failures** (was 103 / 530); parent
**548 runs / 2493 assertions / 0 failures**. New coverage: 7 topology-derivation
tests (including "a self-delegation creates no self-loop" and "an A2A task with
no sender is not an edge"), 5 topology page tests (wire, arrow marker, error
styling, empty state, unattributed inbound), 7 waterfall-arithmetic tests and a
render test, plus a dashboard visual test.

Two bugs of my own were caught by these tests while writing them: `each_cons(2)
.with_index` returns the enumerator rather than the block's spans (needs
`map.with_index`), and the dominant-gap threshold was too low to mean anything.

---

## Phase 22 — the publisher/observer contract (E5-2)

Driver: the observatory's classifier is a **copy** of the harness's topic
grammar, and nothing checked the two against each other. That is exactly how the
claim/lease vocabulary survived the Phase 16 protocol deletion: the observer kept
modelling traffic no producer could emit, its demo published the dead topics, and
the tests asserted them — while the agent filter showed almost nothing on live
data (O5-5).

`test/topic_contract_test.rb` closes the loop in **both** directions:

1. **Producer → observer.** It drives a real dispatcher — card/status announce,
   `subscribe_topics`, a build prompt with a correlated reply, the global-reply
   path, and a delegation — then asserts every topic it published classifies to a
   known kind rather than silently falling through to `other`. The delegation
   assertion also pins the two ends (the topic names the target, the payload's
   `from` names the delegator), because that is what the topology view draws its
   edges from.
2. **Observer → producer.** Every pattern the classifier defines must have a
   representative topic in the test's table, so a new pattern cannot be added
   without a producer to justify it — and the representatives must classify to
   their expected kind, which documents the grammar in one place.

Making that possible required a small structural fix: the kind vocabulary now
lives in the pure `PacketClassifier` (re-exported by the `Packet` model), because
the parent suite cannot load an ActiveRecord model. The two halves of the
contract are now checked against one list instead of two copies that drift.

**Left deliberately uncovered:** `runes/prompts` itself is published by the
*client* (`bin/runes-client`, the TUI), not by an agent, so no dispatcher-driven
run can emit it — it is covered by the representative table instead, and the test
says so.

**Verification:** parent **555 runs / 2551 assertions / 0 failures / 0 errors**;
observatory **124 runs / 629 assertions / 0 failures**; `zeitwerk:check` clean.
The full-suite run caught a leak in this test itself — it overwrote the
process-global `RUNES_ROOT` and deleted that directory in teardown, breaking 11
unrelated tests — which is the same class of global-state leak the round-5 audit
found in the workflow suite (D5-2). File-local `Settings.new(root:)` is the
pattern to use instead.

Still open from the goal: `O0.1` (ingest through `Runes::Transport` — MQTT 5
properties visible, the `mqtt` gem dropped, a broker-free `inproc` mode) and
`E5-6` (guard-aware runes).

---

## Phase 23 — the pitch, as a PDF, generated from its own source

Driver: keep the marketing document honest and make it something you can hand
to someone. `docs/WHY_RUNES.md` was refreshed to match what actually shipped —
the receipts table now carries the real numbers (14 145 lines of `lib`, 10 449
of `test`, 555 runs / 2 551 assertions, observatory 124 / 629, the MQTT 5
adapter's 1 149 lines), the topic map no longer shows the claim/started phase
deleted in Phase 16, a **tenth** thing was added (the console: run timelines,
topology, waterfall, traffic sparkline), and the "what we're honest about" list
was rewritten to lead with the one thing the round-5 research surfaced:
**distribution is exactly-once, execution is at-least-once** and handlers are
not yet idempotent.

`scripts/md_to_pdf.rb` renders a markdown file to a designed PDF (cover band,
section rules, zebra tables, mono code panels, amber callouts, page footers).
It exists so the PDF is the *same text* as the markdown rather than a second
copy that rots: `ruby scripts/md_to_pdf.rb docs/WHY_RUNES.md docs/WHY_RUNES.pdf`
(prawn is a system gem, so this runs outside bundler).

Three bugs of my own, all caught by running it:

- `arr << lines[i] while …` never advances the index — two such one-liners in
  the parser made it hang forever instead of failing. The parser now raises
  "markdown parser stalled at line N" rather than spinning, which is how the
  second occurrence was found.
- `#{1,6}` inside a regex literal is interpolation, not a quantifier: the
  heading pattern had to be escaped.
- Prawn's inline parser decodes `&lt;`, `&gt;` and `&amp;` but **not** `&quot;`,
  so escaping the text HTML-style rendered quotes literally (`&quot;trust
  me&quot;`). Quotes need no escaping in its markup.

**Verification:** the PDF is 5 pages, 202 KB, and reading it back with
`pdf-reader` confirms the tables, code blocks and quotes rendered (no leaked
entities) while `<id>` placeholders survived. Both suites stayed green
throughout: parent **555 / 2551 / 0**, observatory **124 / 629 / 0**. README
and STATE were aligned (the PDF is linked from the intro, the observatory
section names the new views, STATE carries the counts and a handoff block).

---

## Phase 24 — the guard, opt-in, for workflow runes (E5-6)

Driver: the last item of the standing Phase 17 gap. A workflow was a way
*around* the capability guard rather than through it, because `cmd`, `agent`
and `ruby` all execute without asking — and `ruby` is arbitrary code inside the
harness process, which is the largest hazard of the three.

`Runes::WorkflowPolicy` is the seam. It is a separate **top-level** module, not
`Runes::Workflow::Policy`, because `Runes::Workflow` is a class: opening it as a
module first made the class definition fail with "Workflow is not a class" — the
kind of naming collision that only shows up when the load order is wrong.

```bash
RUNES_WORKFLOW_POLICY=config/workflow-policy.json bin/runes-workflow execute w.rb
```

- `cmd` asks with the **command text** as the resource, `agent` with the command
  line it is about to spawn, `ruby` with the rune's name — all before anything
  executes.
- A refusal is `Runes::WorkflowPolicy::Denied` and names the rune, the resource
  and `RUNES_WORKFLOW_POLICY`, so the fix is in the message.
- **Off by default**, because default-deny would break every unmodified Roast
  file: that compatibility is the point of the layer.
- An **unreadable policy fails closed** — the guard refuses everything, and the
  CLI says so on stderr instead of quietly running unguarded.
- Patterns keep the guard's existing semantics: an exact string, or `#` for
  everything. No globs, which makes a narrow policy genuinely narrow.

**Verification:** 8 seam tests (off by default; the environment switch; a denied
`cmd` provably does not create its marker file; a narrow policy allows the
command it names and refuses another; the agent CLI is never spawned; `ruby` is
covered; an unreadable policy refuses with "could not be parsed"; the message
names the env var) plus 2 CLI tests that run the real binstub — one refusal with
exit 1, one unguarded success. Suites: parent **565 / 2590 / 0**, observatory
**124 / 629 / 0**.

Still open from the goal: `O0.1` (observatory ingest through `Runes::Transport`).

---

## Phase 25 — The observer reads the bus the way the fleet writes it (0.3.0)

`docs/OBSERVATORY_ROADMAP.md` O0.1 asked for one thing: stop giving the
observatory its own MQTT client. `MqttIngest` spoke MQTT 3.1.1 through `mqtt`
0.7, so the observer could not see a single MQTT 5 property — not
`response_topic`, not `correlation_id`, not `user_properties` — for the very
messages its whole job is to explain. It was also a second, divergent MQTT
implementation in a project that had just finished deleting one.

`MqttIngest` is gone. `FabricIngest` subscribes through `Runes::Transport`, the
same seam the fleet publishes through, and hands each `Runes::Transport::Message`
to the recorder:

```ruby
transport.subscribe(@topic)    { |message| consume(message) }
transport.subscribe(A2A_TOPIC) { |message| consume(message) }
```

`properties` is the transport-neutral subset (`response_topic`,
`correlation_id`, `user_properties`), so the observer now stores what the
transport saw: `properties` moves from the adapter's memory into columns.

- **Two migrations.** `packets` gains `qos`, `retain`, `correlation_id`
  (indexed: it is the join key that survives an unparseable payload),
  `response_topic` and `user_properties` (JSON text); `ingest_statuses` gains
  `transport`, because "connected" to `127.0.0.1:1883` is a lie when the ingest
  is attached to a hub inside its own process.
- **User properties are bounded on the way in** — 32 pairs, 512 bytes per
  value, truncated *per value* and never on the encoded JSON, so what is stored
  always parses. A publisher controls its headers; it must not be able to write
  a megabyte per packet into the database.
- **Reconnection is layered, not duplicated.** A transient drop is the
  adapter's business: MQTT 5 reconnects and re-subscribes on its own and reports
  through `on_health`, which the ingest mirrors into `IngestStatus` *and* into
  the retained-replay dedupe window (otherwise a long outage stores every
  retained card twice). A drop that outlasts `DISCONNECT_GRACE_S` is ours:
  `FabricIngest` rebuilds the transport with exponential backoff. Without the
  split, the observer's backoff and the adapter's reconnect would fight.
- **`RUNES_TRANSPORT=inproc` runs the whole observatory with no broker.** That
  is not a demo flag: it is how the ingest is now tested — a real transport, a
  real recorder, no mosquitto and no fake client (one scripted transport
  stands in only for the *outage* case, where a real one cannot be made to die
  on cue). `RUNES_TRANSPORT=mqtt5` upgrades to properties; `auto` (the default) tries mqtt5 → mqtt311 → inproc
  and warns loudly if it lands on inproc, because a process-local hub is deaf to
  a broker-based fleet.
- **No gem dependency on the harness.** `runes` declares `mqtt ~> 0.7` as a
  runtime dependency, so depending on the gem would have re-introduced exactly
  the client this change is about. An initializer puts the sibling checkout's
  `lib` on the load path instead (`RUNES_HARNESS_LIB` overrides it); the web
  process still boots if the harness is absent, and only the ingest fails,
  loudly, if it needs it.

**Verification.** `FabricIngestTest` drives a real `InProcess` hub end to end:
a broker-free ingest records what a publisher puts on the fabric; MQTT 5
properties (including a 5 000-byte value, truncated to 512 and still valid
JSON) reach the database; a bad message is counted and dropped while the good
one lands; a non-UTF-8 payload does not tear the subscription down; the retain
flag reaches the recorder; and a dead transport is rebuilt with backoff instead
of hanging forever. `FabricIngestLockTest` still reproduces O5-3 (a second
connection holds `BEGIN EXCLUSIVE`) — and, being the suite's one
non-transactional test, it now cleans up precisely the two request ids it owns:
its first version deleted every packet, which silently ate the fixture rows
every page test depends on and turned a green suite into 9 failures and 5
errors.

**Verified live** against mosquitto 2.1.2 with `RUNES_TRANSPORT=mqtt5`:
`scripts/mqtt5_observer_probe.rb` published one A2A-shaped message, and the row came
back with `correlation_id`, `response_topic`,
`user_properties = {"a2a-status":"working","probe-tag":…}` and
`ingest_statuses.transport = "MQTT5"`. The `qos` column stores the **delivery**
QoS (the ingest subscribes at QoS 0, so a QoS 1 publish is stored as 0) — the
honest number for "what we received".

The live probe also surfaced a real gap, recorded in the roadmap rather than
papered over: `runes/a2a/tasks/…` classifies as `other`. The observer recognises
`$a2a/#`, not the `runes/a2a/…` spelling; one of the two should change.

### The gem that was not optional after all

Dropping `gem "mqtt"` from this app's Gemfile exposed a bug in the seam it was
supposed to make optional. `lib/runes/transport.rb` eagerly required the 3.1.1
adapter, and *that* file requires `mqtt` at the top — so in an app without the
gem, `require "runes/transport"` raised after base and inproc had loaded. The
result was a **half-defined module**: `Runes::Transport::InProcess` existed,
`Runes::Transport.build` did not. The observer's initializer logged the
LoadError as a warning, and the ingest then failed with the gloriously
unhelpful `undefined method 'build' for module Runes::Transport` — eight times,
with backoff, before I read the log.

"MQTT is a choice, not a requirement" is that file's own first sentence, so the
fix belongs in the harness rather than in a Gemfile:

- `lib/runes/transport.rb` loads the 3.1.1 adapter **on demand**, exactly like
  the MQTT 5 one, so the seam is whole without a client library.
- `lib/runes.rb` still requires it up front, guarded — a gem install gets
  `Runes::Transport::MQTT311` as before, and `test/transport_test.rb` (which
  drives that adapter directly) now asks for it explicitly.
- `test/transport_test.rb` gains two subprocess tests that shadow `mqtt` with a
  file that refuses to load: the seam must define `Transport.build` anyway, and
  asking for `mqtt311` must raise a LoadError that *names the gem*. That is the
  regression test for the whole episode; it would have caught it in the parent
  suite, where it belonged.
- `FabricIngest` rescues `LoadError` alongside `StandardError` (LoadError is a
  `ScriptError`, so a missing gem would otherwise have killed the process
  outright) and, for this one case, logs what to do: add `gem "mqtt", "~> 0.7"`
  to the observer's Gemfile, or use `mqtt5`/`inproc`, which need nothing.

Live check with the gem gone: the observer's default `auto` mode still attached
as `MQTT5` and stored `correlation_id`, `response_topic` and `user_properties`;
`RUNES_TRANSPORT=mqtt311` logged the hint and kept retrying instead of dying.

Suites: parent **567 / 2593 / 0**, observatory **131 / 658 / 0**.

That same audit of "does the PDF actually say what the markdown says?" found a
worse bug, in the renderer rather than the prose: `split("|")[1..-2]` dropped
Ruby's trailing empty field, so every table row parsed as **one** cell and the
PDF silently lost the value column of every table it ever rendered — including
the receipts table it was built to keep honest. The fix is `split("|", -1)`,
plus a parser guard that raises on ragged rows so a malformed table is loud
instead of half-drawn. The renderer and the live observer probe now live in
`scripts/` (tracked) rather than gitignored `tmp/`: the "the PDF is the same
text as the markdown" invariant is only reproducible if the tool that enforces
it is in the repository. `docs/WHY_RUNES.pdf` is 7 pages with all table values
present.

---

## Phase 26 — Closing P0: witness only, health you can judge, and the second source (0.3.0)

Batch A of the agreed plan: the three P0 items O0.1 left behind.

### O0.6 — the observer must never be a worker

`assert_not_a_worker!` runs after the two subscriptions and inspects the live
subscription set: any `group:` or `$share/` filter raises `WorkGroupRefusal`
naming the offending filter and explaining that on MQTT 5 the broker would have
handed the observer exactly one member's share of the prompts, which it has no
worker pool to run. It is a runtime check rather than a comment because the
risk is one copy-paste away: since O0.1 the observer subscribes through the same
API as the agents. Two tests pin it — the real inproc ingest must expose exactly
`runes/#` and `$a2a/#` with no group, and a deliberately grouped transport must
be refused.

### O0.5 — "is this feed trustworthy right now?"

`ingest_statuses` gained `reconnects` and `last_lag_ms`; the dashboard panel
gained rate, lag and reconnects, and turns the lag red past 30 s.

Getting an honest lag figure was the real work. `occurred_at` had always been
our receipt time, so a packet's own age was unknowable and `received - occurred`
would have been a constant zero. The recorder now believes a payload's clock
when it carries one — the journal writes `at` (ISO 8601), a signed envelope
carries `ts` (unix seconds) — and only when it is plausible (≤60 s in the
future, ≤7 days old), because a publisher may claim any time it likes and a
wrong `occurred_at` silently reorders the timeline. `nil` lag means "the
publisher sent no clock": `0` would be a lie, and the panel says
*unknown (publisher sent no clock)*.

That change surfaced its own bug immediately: `initialize` defaulted
`@occurred_at = occurred_at || received_at`, so `record` could never tell "the
caller supplied a time" from "nobody did" and the clock extraction never ran.
Three of my own new tests failed on it, which is exactly why they exist.

`packets_per_minute` is derived from the `packets` table rather than from a
counter: a reconnect resets `started_at`, and a process restart resets
everything, so a counter-based rate would drift away from the truth.

### O0.7 — the durable journal becomes history

`JournalTail` follows `<repo>/log/journal.jsonl` — the same payloads the harness
publishes on `runes/_log/prompts`, but on disk, which is the only thing that
survives a broker restart or an observer that was simply down. It tracks inode
and byte offset, holds a partial line until its newline arrives, re-reads from
zero on rotation (the archive is a timestamped sibling) or truncation, bounds a
line that never ends at 64 KiB, and runs on the ingest's timer threads so it
does not depend on the broker.

The part that makes two sources safe is one query: before storing a line it
checks whether that exact `(topic, payload)` row already exists. An entry the
observer heard on the bus is not stored twice when the file is read, a restart
that re-reads the whole file cannot duplicate rows, and a truncated file that is
re-read cannot either. Off in tests (`RUNES_OBSERVER_JOURNAL=off` in
`test_helper.rb`) so the suite never tails the developer's real journal — that
default path *does* exist in this checkout, and a background tail inserting rows
would have made counts and ordering depend on the last local run.

Nine tests cover the tail: read-once-in-order, cross-source dedupe, a partial
line, rotation, truncation, a recorder failure (counted, and the next line still
lands), an unparseable line (stored, not dropped — the MQTT path's behaviour),
the unbounded partial line, and the environment switch.

Suites: parent **567 / 2592 / 0**, observatory **152 / 736 / 0**.

---

## Phase 27 — Who really published this (0.3.0, Batch B)

doc5.md O0.3 and the last of O0.2's columns. `PacketRecorder` used to take the
payload's `agent` field at face value: the observer could show a name and had no
way to say whether anything backed it, on a shared broker, which is the one
place where that question matters.

`ObserverSignature.check` now runs on every parsed payload and stores
`signature_state` + `key_fingerprint`:

| State | Means |
| --- | --- |
| `unsigned` | no `sig`/`alg`/`kid` — most fabric traffic, or a payload we cannot parse |
| `verified` | the Ed25519 signature checks out against a key in the trust store |
| `untrusted` | signed with a key the store does not hold (`:unknown_key`): the claim may be honest, but nothing here can confirm it |
| `invalid` | provably wrong (`:bad_signature`, `:malformed`) |

Decisions worth recording:

- **`require_fresh: false`, no replay guard.** Freshness and replay matter when a
  message is about to *cause work*; the observer is a witness, and a
  stale-but-authentic packet is still authentic history. A replay guard would
  also make the verdict depend on read order, which is precisely what
  contradicts "witness". The cost is stated in the roadmap: an attacker can
  replay an old authentic packet and the observer will call it `verified` — it
  will also show you its `ts`.
- **A missing trust directory is an empty store, not an error.** Signed traffic
  then reads `untrusted`. Fail-closed in the direction that matters.
- **An empty store cannot tell a forgery from a stranger**, so it does not
  pretend to: `:unknown_key` is `untrusted`, never `invalid`. The test for a
  tampered payload had to put the key in the store first to earn `invalid` —
  a nice demonstration of why the distinction is honest.
- **Memoized per `(kid, digest)`**, because a broker replays retained packets on
  every reconnect and re-verifying identical bytes is pure waste.
- **A verifier exception is `invalid`, never `verified`.** The recorder wraps the
  whole call as well: a witness that stops recording because a signature is odd
  is worse than one that records the oddity.

`ImpersonationDetector` derives findings from stored packets — so they survive a
restart — in two shapes: **split identity** (one `agent_id` with two
fingerprints) and **wrong key** (the fingerprint is not the one the trust store
holds for the agent the payload claims to be). The dashboard's Security panel
shows the hour's counts, the findings with both fingerprints side by side, and,
under `RUNES_OBSERVER_REQUIRE_SIGNATURES=1`, how many packets in the last hour
are unsigned — because on a shared broker an unproven `agent` field should not
be quiet. Packets are badged in the feed (signed ones only, so an unsigned
majority stays quiet), fully labelled on the packet page, and each agent page
lists every key it has been seen with.

**Verified live** against mosquitto 2.1.2, not just in tests:
`RUNES_PROBE_SIGN=1 RUNES_PROBE_TRUST_DIR=/tmp/runes-probe-trust ruby
scripts/mqtt5_observer_probe.rb` signed an A2A-shaped envelope with a freshly
generated Ed25519 key and published it; the stored row came back
`signature_state = verified`, `key_fingerprint = d01deeea…` — the signing key —
alongside the MQTT 5 properties from Phase 25. The probe now does both checks,
and can write the public key into a trust directory for the ingest to read.

Suites: parent **567 / 2592 / 0**, observatory **178 / 835 / 0** (+26 tests).

---

## Phase 28 — Refusals are visible now (0.3.0, O2.3)

The last piece of the security story. Phase 27 answered *who published this*;
what was *refused* still never left the process — a warning line in a log
nobody keeps. Every S4-1/S4-2 class finding in the round-5 audit was about
refusals that did not happen, and a refusal you cannot see is a refusal you
cannot notice.

`Runes::GuardTelemetry` is the seam, shaped deliberately like
`Runes::Telemetry`: a **sink** decides what a decision is worth.

```ruby
Runes::GuardTelemetry.sink = ->(decision) { ... }
Runes::GuardTelemetry.sink = Runes::GuardTelemetry::TransportSink.new(
  transport: t, agent_id: 'a1'
)
```

A decision is `{tool, action, resource, phase, agent, at}`; the transport sink
publishes it on `runes/guard/denied`. Wiring:

- the capability guard reports from `log_deny` — the *log line* stays
  deduplicated (a repeated identical line is noise) while the *event* does not
  (how often a refusal happens is exactly what an operator wants to see);
- the dispatcher attaches a sink to its transport automatically, so every
  agent publishes its own refusals without configuration;
- `bin/runes-workflow` reports `RUNES_WORKFLOW_POLICY` refusals on the same
  topic, through the same transport its run telemetry already uses.

Two decisions worth recording. `Guard#allowed?` grew `report:` because the
workflow policy knows it refused a *rune* and reports that itself with
`phase: "workflow"` — without the flag one refusal produced two events, which
the new test caught immediately. And emitting is rate-capped at
`MAX_PER_MINUTE` with a single warning, because a planner in a loop must not be
able to turn the guard into a fabric flood: a telemetry seam that can be
weaponised is a worse bug than a missing event. A raising sink is swallowed,
like every other telemetry path.

`/security` is the page: refusals per hour / 24 h / all-time, a 30-minute
refusal sparkline, top tools and agents (each one a filter), every row linking
to the packet that recorded it, and — beside it, because they are two halves of
one question — the signature verdicts and impersonation findings from Phase 27.
The dashboard keeps a compact summary and links here. `PacketClassifier` maps
the topic to `guard_denied`, and the parent suite's topic-contract test carries
a representative topic for it, so the publisher and the observer cannot drift.

**Verified live** against mosquitto 2.1.2: with the ingest attached,
`RUNES_PROBE_RESOURCE="rm -rf /tmp/live-$$" ruby scripts/guard_denial_probe.rb`
published a real refusal through the real seam, and the observer stored
`kind: guard_denied`, `tool: run_command`, `event: exec`,
`agent_id: probe-agent`, with `occurred_at` taken from the publisher's own
clock (the Phase 26 work, doing its job one phase later).

Suites: parent **578 / 2632 / 0**, observatory **188 / 890 / 0**.

---

## Phase 29 — Execution is deduped now (0.3.0)

The honesty list in `docs/WHY_RUNES.md` led with this one: *"distribution is
exactly-once; execution is at-least-once... a duplicate prompt or task can
repeat its side effects."* Shared subscriptions made MQTT 5 hand each prompt to
one group member, but nothing deduped what arrived:

- a QoS 1 PUBLISH whose PUBACK is lost is retransmitted, and the adapter
  delivers it to the handler a second time;
- a client configured with a session expiry gets unacknowledged messages back
  after a reconnect;
- any publisher that retries on timeout sends the same request again.

Each of those could run one prompt twice: two LLM bills and two sets of tool
side effects from one request. `Runes::RequestLedger` closes the window:

```ruby
ledger.claim(RequestLedger.prompt_key("abc"))   # true the first time only
ledger.complete(RequestLedger.prompt_key("abc"), "complete: wrote lib/x.rb")
ledger.outcome(RequestLedger.prompt_key("abc")) # for a replay, not a re-run
```

`claim` is atomic (two transport threads delivering the same message cannot both
win — there is a 16-thread test), bounded (`max`, oldest evicted first), TTL'd
(900 s default, `max` and `ttl` injectable, and a fake clock so the tests never
sleep). `handle_prompt` claims **before** any work is queued, so a duplicate
never reaches the worker pool; the duplicate is announced on the progress topic
(`duplicate_ignored`) with the first copy's outcome, and — once the first copy
has finished — the reply topic is answered from the ledger instead of being
silently dropped. `record_prompt_log` is the completion hook, which every mode
already calls with a status and summary.

One claim covers every inbound path, because prompts, A2A tasks and delegations
all funnel through `handle_prompt`; the opt-in direct tool RPC claims separately
on `(tool, request_id)`.

The claim sits **after the signature gate and before the work queue** on
purpose: after, because keying on an unverified `request_id` would let any
publisher poison the ledger with someone else's id and suppress the legitimate
request that follows; before, because a redelivery must not consume a worker
slot the first copy could use. A test drives a real `InProcess` transport and
publishes the same envelope twice through the subscription — the dedupe is
pinned where a redelivery actually arrives, not only where the method is
called.

Three things this phase is honest about:

- **A plain prompt is not deduped.** Its id is a digest of its text, so two
  deliberate repeats are indistinguishable from one retry, and eating a user's
  second identical prompt is worse than re-running it. Only an envelope that
  names a `request_id` has an identity to dedupe on.
- **The ledger is in-process.** It covers redelivery and retries inside one
  process lifetime, which is where the exposure lives: the MQTT 5 adapter
  connects with `session_expiry: 0` (a clean session), so the broker does not
  replay messages from before a disconnect. A deployment that turns session
  expiry on *and* restarts should expect re-runs; a durable ledger (the
  `sqlite3` the harness already depends on) is the next step if that matters.
- **A reused `request_id` is a new request once the TTL lapses**, which is what
  makes a long-lived agent's memory bounded.

Two bugs of my own, both caught by the suite rather than by review. Adopting the
delegation's `request_id` for dedupe first set `from_envelope: true` on the inner
envelope — but that flag *also* derives a conventional reply topic, so a
delegation with an unsafe `from` (which must have its reply suppressed, the D10
regression test) got one anyway. The fabric now sets an explicit
`dedupe_key`, which is exactly the statement "this envelope has a verified
identity but must not derive a reply topic from it". And the parent suite
revealed that "all green" had been order-dependent: `test_helper` never loaded
the 3.1.1 adapter, so six suites only worked when another file happened to load
it first — which the lazy-`mqtt`-gem change had quietly broken. `test_helper`
now requires it once.

Suites: parent **600 / 2696 / 0**, observatory **188 / 890 / 0**.

---

## Phase 31 — The fleet board: planned / working / done, as Mermaid (0.3.0)

The idea came from `pipeline_prospect`, where a mission's kanban *is* a `.mmd`
file shared between the Rails app and external harnesses. Two things there are
worth stealing, and one is worth fixing:

- **the diagram text is the artifact** — it renders in a browser *and* it is
  readable by a program;
- **the board must survive Mermaid being unavailable** — their JS falls back to
  an HTML board;
- **but the CDN is not**: Runes' doctrine is local-first, so Mermaid is vendored
  (`vendor/assets/mermaid.min.js`, 3.57 MB, MIT, with `mermaid.LICENSE.txt`).

`Board::Kanban` folds the packet stream the observer already stores into three
columns. No new ingestion, and no invention:

| Column | Folded from |
| --- | --- |
| Planned | `plan_ready` (N steps announced), `mission_written`, an addressed `a2a_task` |
| Working | `prompt_received`, `step_start <tool>`, `mission_step_start <title>` |
| Done | `step_end`, `prompt_complete`, `mission_step_done/failed`, `mission_complete`, every journal entry |

The fold is chronological and **keyed**, which is the whole point of a board: a
step announced as `step 2` becomes the same card when it starts (now titled with
its tool) and when it ends (with its outcome). Three honesty rules fell out of
writing it:

- **A planned step has no name yet.** The dispatcher publishes the *count*
  (`plan_ready {steps: n}`) and only names each step when it starts, so a planned
  card is honestly "step N" until then.
- **Quiet is not finished.** A Working card with no signal for over
  `STALE_AFTER` (30 min) stays in Working and is flagged (⚠), because a wedged
  request is exactly what a board should surface.
- **Closing is not doing.** When a request ends, steps still open are closed
  ("closed with the request") and steps never reached are closed *and* flagged
  ("not started when the request finished") — leaving either in Working/Planned
  for ever would be the board lying.

A journal entry is also the board's best source of titled finished work: it is
written at the end of a lifecycle and carries the prompt text, so history shows
up even for a request whose progress events the observer never saw. A
`mission_step` entry closes *that todo* and deliberately leaves the mission
running.

`/board` renders the diagram with the vendored Mermaid **over** a
server-rendered HTML board, so the page is correct with JavaScript disabled and
a Mermaid failure costs nothing (the controller keeps the list). `GET /board.mmd`
returns the same text as `text/plain; charset=utf-8` — that is the artifact an
agent, a harness or `bin/runes-replay` can read without a browser. The generated
diagram is grammar-checked by `Board::Kanban.validate` in the suite, so a
malformed diagram fails CI rather than rendering an error box in a browser
nobody is watching.

**Verified live**, not just in tests: seeded the demo session
(`bin/rails runes:demo`), ran the dev server, and `GET /board.mmd` returned 8
Done cards with real titles ("runes-studio-4013 · write_file — Wrote
CHANGELOG.md (489B)"), `GET /board` carried the Stimulus container, the three
columns and 8 cards, and the vendored bundle served as
`/assets/mermaid.min-3295a0a6.js` (3 572 661 bytes, `text/javascript`). The one
thing I could not verify without a browser is the *rendered SVG*; that is
precisely why the HTML board is server-rendered rather than drawn in JS.

Suites: parent **600 / 2696 / 0**, observatory **215 / 1069 / 0** (+27 tests).

One thing the board work surfaced in the *pitch tooling*: regenerating
`docs/WHY_RUNES.pdf` produced two pages carrying nothing but the footer. The
cause was in `scripts/md_to_pdf.rb`, not the document: bullets are drawn inside
a Prawn `bounding_box`, and a bounding box does not flow across a page break —
drawn at a cursor below the page bottom, the text is clipped and the page is
left blank. Every non-flowing block (bullets, paragraphs, headings, quotes,
code panels, tables) now calls `ensure_room` and breaks *before* drawing, and
the renderer checks its own output for pages that carry only the footer and
warns instead of shipping a PDF with holes. 9 pages (2 blank) → **7 pages, 0
blank**.

---

## Phase 32 — The anti-SaaS spike: a whole pipeline as one workflow (0.3.0)

The question was whether a real product's *engine* — the part that is
intelligence — can be a DSL file instead of a Rails app, and thereby become
something a team can tweak in one line. The answer, after building it, is yes
for the engine and no for the surface, and the two are now separable in the
repo.

Two pieces, both tested:

- **`lib/runes/kanban.rb` (297 lines, 14 tests).** The mission `.mmd` format is
  not invented here: it is the contract `pipeline_prospect` publishes in its
  `HARNESS.md`, and the test fixture is that file's own sample, verbatim — the
  round trip `render(**parse(text))` is lossless. `validate` mirrors their
  `scripts/harness/validate_mermaid.rb`, so a workflow cannot write a file their
  tooling rejects. `advance` keeps the reason a card moved as free text after
  the assignee suffix, which is the one place the grammar allows it.
- **`examples/prospect_pipeline.rb` (431 lines, 4 tests).** Idea → `goal.md`
  (with a minted `#E-001` reference) → mission kanban → every todo worked and
  *verified* by a second agent call → CRM next actions by a deterministic rule →
  drafted outreach written to `outbox/` and never sent → weekly report. The
  test runs that exact file end to end offline in ~50 ms with the provider seam
  scripted, and asserts the artifacts: the kanban validates, one todo passes to
  Done, one fails to Blocked with its reason preserved, mission status derives
  to Blocked, two drafts exist and say "non envoyé", the report carries the
  failure, and the epic codes increment across runs while mission codes stay
  per-epic (their rule).

Three DSL lessons worth writing down, because I got each of them wrong first:

- **`from(call!(:x))` returns the raw value**, not a rune output. `plan.todos`
  does not work; `plan[:todos]` does. (`ruby!(:x).key` *does* work — the Ruby
  rune's output delegates missing methods to its value — which is exactly the
  kind of asymmetry a user hits on day one, so the example now shows the
  unambiguous form.)
- **`collect(map!(:x))` returns whatever the sub-scope's `outputs` block
  returned**, so my `.map(&:value)` was wrong once the sub-scope returned plain
  hashes. It also cannot be called from a `call` block (it sees no managers);
  a `ruby` step is the place to read a map's iterations.
- **Key types are a real hazard.** The model returns JSON (string keys), Ruby
  builds symbols: the report was silently empty until every boundary symbolized
  once (`JSON.parse(..., symbolize_names: true)`) and everything downstream
  agreed.

Also honest: the workflow needed one thing its "no new dependency" framing
would miss — `lib/runes/workflow.rb` now loads `Runes::Kanban`, because a
workflow file's constants have to be available to the CLI. And the receipts are
deliberately not a LOC-versus-LOC claim: the Rails app it borrows its format
from is 3 758 lines of app code *plus* a product surface (forms, pages, JSON
API, serializers) this workflow does not replace, and its own SaaS roadmap adds
five sprints of auth, tenancy, billing and GDPR on top. What the workflow
replaces is the engine; what it inherits from Runes is the part a PoC usually
gets wrong — ledger dedupe, journal resume, visible refusals, `/board`, replay.

Docs: `docs/EXAMPLE_CRM_PIPELINE.md` (the pitch, the one-line tweak table, the
measured receipts, what it is not), README, and `docs/WHY_RUNES.md` item 8 —
*the alternative to a SaaS is not a smaller SaaS, it is a file*. `scripts/receipts.rb`
now prints examples too.

Suites: parent **618 / 2802 / 0**, observatory **215 / 1069 / 0**.

---

## Phase 33 — D0→D4 complete, a review that found five real flaws, and a DSL guide (0.3.0)

The five directions from the spike are now all in the tree, and the review pass
over the new code found more than the feature work did.

**D1 finished — the data layer (213 lines, 12 tests).** `Runes::DocStore`
(`ab/cd/<sha256>.<ext>`, two shards, dedupe, write-then-rename so a reader never
sees a half-written document under a content address) and `Runes::Index` (the
`#E-001` / `#M-001` codes resolved by scanning the files, because on disk the
files *are* the index). The index handles the property that makes codes
interesting: epic codes are global, mission codes are per-epic, so `resolve`
takes `from:` and prefers the path inside the same epic — and `link` reports
references that point nowhere instead of inventing them. Both are **libraries,
not new verbs**, on purpose: a workflow file that runs unmodified under Roast
cannot depend on an eighth verb, and `ruby { Runes::DocStore.put(...) }` costs
one line. That reasoning is now written into the code and the guide.

**D3 completed.** `/board` now folds `WorkflowRun`/`WorkflowStep` rows too, so a
`RUNES_TELEMETRY=mqtt bin/runes-workflow execute …` run appears on the board as
Working/Done cards with rune, workflow and duration. This corrected a claim I
had already written: `docs/EXAMPLE_CRM_PIPELINE.md` said the pipeline was
watchable as *planned/working/done*, which was false for a workflow run — the
engine names a step when it starts, so a workflow contributes no Planned cards.
The board's doc comment, the guide and the roadmap now say that plainly.

**The review found five real flaws**, four of them in code I had just written:

1. **Model text could restructure the kanban.** A title from the model is
   interpolated into a file a human and another app read: a newline, a forged
   `- [x]`, a leading list marker or a literal `(Assigné: …)` could forge tasks
   or steal an assignee. Titles and headers are now sanitised at the single
   choke point (`coerce_task`), with a test that a hostile title stays one line
   and exactly one real assignee suffix survives.
2. **`advance_file` was an unlocked read-modify-write** on a file three writers
   share (workflow, `$EDITOR`, the app). `update_file` now holds `flock(LOCK_EX)`
   for the whole read-modify-write and writes in place instead of truncating;
   the test runs two threads moving two tasks and asserts both moves survive.
3. **Nothing checked what was written.** The workflow now validates the mission
   after writing it *and* after every move, and `fail!`s with the first grammar
   error — which is what makes "it cannot write a file their tooling rejects"
   true rather than aspirational.
4. **A reference regex dropped a real reference.** `\b` after a code does not
   match before `_`, so `#M-001` at the end of a Markdown emphasis — exactly
   what the weekly report wrote — was silently ignored. The boundary is now
   "not followed by another code character", with a test for emphasis,
   punctuation, a trailing comma and the 4-digit overflow case.
5. **The doc claimed a board view the code did not provide** (the D3 item
   above). Corrected in the code *and* the prose.

**The new marketing document.** `docs/DSL_POWER.md` (+ PDF, generated from the
markdown like `WHY_RUNES.pdf`) — *The DSL, or: one file that replaced a
product's engine*. It is the companion to `WHY_RUNES.md`: the whole DSL on one
page (seven verbs, the block contract, the readers, `from`/`collect`/`reduce`,
`fail!`), the pipeline scope by scope with the real code, **the three sharp
edges** I hit while writing it (`from(...)` returns the raw value,
`collect(map!...)` returns the sub-scope's outputs and cannot be called from a
`call` block, and key types), why the loop is fun (50 ms, files you can open,
a verb in 30 lines, Roast interop), why it is safe to leave running, the
one-line tweak table, and the honest boundaries. Both PDFs are generated by
`ruby scripts/md_to_pdf.rb <md> <pdf>` and are checked for blank pages by the
renderer itself.

Suites: parent **636 / 2879 / 0**, observatory **219 / 1085 / 0**.

## Phase 34 — The Spinel kernel: from subset to a verified native binary (0.3.0)

**The bet.** The WASI-guest roadmap (compiled agents as capability-sandboxed
guests) has a first mile that can be walked today: [Spinel](https://github.com/matz/spinel),
Matz's Ruby AOT compiler, turns a Ruby subset into a standalone native
binary — no CRuby at runtime. The question was never "can we compile
`bin/runes`" (sockets, Open3 and Rails say no) but "what is the largest
useful subset that compiles, verifiably, without breaking the harness". The
answer shipped in three tiers plus a gate, and the first native build
passed all 70 kernel self-checks on 2026-10-01.

**Tier A — the pure kernel.** The CPU-bound, security-relevant core was
decoupled from the stdlibs a compiled runtime lacks: facades
(`Runes::Json` + a strict pure-Ruby parser pinned to stdlib byte-for-byte
including its nesting rule, `Runes::SHA256` pure FIPS 180-4, `Runes::Random`
with a pure id-PRNG and a CSPRNG FFI path), `Runes::Compat` (civil-date
arithmetic, ISO-8601, base64/hex, dotenv — all dependency-free), and a
subset sweep: `def self.` instead of `module_function`, plain classes
instead of `keyword_init` Structs, no `filter_map`/`each_with_object`/endless
defs, `GuardTelemetry` split into a pure core and a transport sink. A CRuby
self-check entry (`spin/kernel_cruby.rb`) runs the identical checks with
Fiddle-bound C libraries, so the kernel is verifiable with no compiler
installed.

**Tier B — FFI backends, manifest-audited.** `Runes::Native` with a single
manifest of C functions bound two ways: a Fiddle binder (CRuby — drives the
real libcrypto on the dev machine, cross-checked against OpenSSL in both
directions) and a Spinel `ffi_func` file (parse- and manifest-audited so
the binders cannot drift). Ed25519, HMAC-SHA256 (RFC 4231 pinned), CSPRNG
(`arc4random`/`getrandom`, later one `ffi_source` C adapter), and a pure
PKCS#8/SPKI DER codec that round-trips OpenSSL keys byte-for-byte — existing
`kid` fingerprints unchanged. Settings grew a store seam (SQLite stays the
CRuby default; a pure atomic JSONL store compiles).

**Tier C — the two real walls, one fallen.** `Open3` was replaced by
`Runes::ProcessSpawner` over `posix_spawn`: dup2'd pipe triple, child-side
chdir, `SETPGROUP` for orphan-free kills, exact env — the full `run_confined`
containment without a shell. The workflow engine got class-body static
bindings for its verbs (registry dispatch through `Runes::Plugin`), with
the dynamic conveniences (`Config.field`, ruby-output `method_missing`
delegation, ERB templates, `use`) moved to CRuby-only extension files behind
the `Runes::Runtime` seam. Sockets and the wasmtime gem stay on the CRuby
shell, deliberately (spec in `docs/spinel/spec-tier-c.md`).

**The gate.** `test/spinel_subset_test.rb` lints 47 kernel files for the
blocked constructs (computed `define_method`, string eval, missing stdlibs,
`&:`/`.b`/`pack`… — each pre-empted or banned after the first build taught
us where the floor is), audits the kernel's require closure, and pins the
pure backends to stdlib/OpenSSL. The same file runs the self-check in CRuby
parity mode; `scripts/spinel_build.rb` compiles with `spinel` when one is on
`PATH` (`SPINEL=…`) and runs the native checks otherwise — the suite never
requires the compiler.

**The first native build** (spinel 2026.09.12+3496, macOS arm64) surfaced
eight genuine compiler quirks, each worked around in the code with a
comment: an accumulator passed by value that silently dropped every `<<`
(fixed in pure value style), whole-program builds missing `IO::Buffer`
uses in required-file lambdas (fixed with a main-path probe constant),
`:U64` reads disagreeing with C's little-endian out-params (fixed with
byte-wise composition), `define_singleton_method`/`extend` unsupported
(class-body dispatch), analysis-time constant folding of module-state
predicates (probe by doing, not asking), `send(name)` refused (static call
lists), the `Cog = Rune` alias invisible to the analyzer (compiled code
spells `Runes::Rune::*`), and `pack`/`unpack`/`format` landmines (pure
`Compat` replacements). `build/runes-kernel` is 1.8 MB and runs the full
70-check self-check in ~40–50 ms; the CRuby parity entry needs ~150–310 ms
for the same work. Every finding is catalogued in
`docs/spinel/spec-tier-a.md` §VERIFY — several read like upstream bug
reports.

**Honest boundaries.** Evaluating a workflow *file* is `instance_eval` of a
string — an AOT compiler cannot do it; compiled kernels bake workflows in
at build time (`Runes::Runtime.eval_workflow_source` raises otherwise; the
CRuby parity entry overrides it so the engine is exercised end-to-end
today). Chat/agent runes, sockets and Rails stay interpreted — the
supported topology is a compiled kernel talking to a thin CRuby I/O shell
through the existing transport seams. Exit statuses of FFI-spawned children
are CRuby-unavailable (Ruby's SIGCHLD reaper owns them); a compiled kernel
reads real statuses.

Suites: parent **681 / 4392 / 0**, observatory **219 / 1085 / 0** (as of the
native build; `scripts/receipts.rb --suites` re-measures).

## Phase 35 — The Fleet DSL, phase A: the world layer loads fail-closed (0.4.0)

**Where this sits.** 0.4.0 is the fleet layer of `docs/FLEET_DSL.md`: a
declarative world + rules document in a restricted, statically analyzable
Ruby subset — the Inform 7 lesson (a declared world, rules that fire on
change) with discipline instead of natural-language parsing. Phase A ships
the world half at L1 conformance; rules (§5) and the lowering onto the
seven runes (§9) are the next phase.

**The walker is the gate.** `Runes::Fleet.load_file` runs three stages, any
failure raising `Fleet::LoadError` and leaving zero partial world (P3/§10):
the `# fleet-spec: 0.1` header is checked lexically (§13, visible to grep
and to the future L3 gate without evaluation); a Prism whitelist walker
denies by default — eval, defs, constant reads, receiver calls,
interpolation, globals, control flow, lambdas, backticks all abort with a
line-numbered error (§6), with an explicit `method_missing` net because
Prism's `accept` dispatch has no reliable visit_missing fallback; only then
does the fixed binding evaluate the declarations (`fleet`/`agent`/
`channel`/`route`/`fact`/`schedule`/`config`), the builders enforcing
placement, duplicate ids, ACL-safe tokens, `runes/`-prefixed topics and
5-field crons. One loud call recorded in code: an agent with no `tools`
clause is a load error — default-deny is explicit, `tools :none` is how a
role says "I only watch".

**A spec correction, caught by the compiler we were writing.** The draft's
route syntax `route :a => :b => :c` is not valid Ruby — `=>` does not chain
inside or outside braces (the early spec example could never have
evaluated). The surface is positional: `route :scraper, :writer,
:reviewer` declares a path (one edge per consecutive pair),
`route :reviewer, :outbox, when: :accepted` a guarded edge, and the keyword
spelling stays as sugar for single pairs. §4.4 and the §12 example are
corrected in place, and the §12 world needed its `:outbox` channel
declared for the route to validate.

**The guard can already see it.** Loading produces the §8 extracts without
any runtime: the policy extract (every `tools` clause merged, `default_allow`
pinned false), the ACL extract (route edges authorize exactly the target's
`runes/agents/<id>/tasks` write or the channel topic — nothing more, no
catch-all; the base card/status grants stay `bin/runes-acl`'s job), and the
topology graph in the observatory's shape with `rules: []` until phase B.
`world.fingerprint` hashes the extracts through the kernel's own
`Runes::Json`/`Runes::SHA256` seams — the determinism certificate seed
(§8.4) is dogfooded kernel code. `prism` becomes a declared gemspec
dependency.

Suites: parent **708 / 4581 / 0** (`scripts/receipts.rb --suites`
re-measures).

## Phase 36 — The Fleet DSL, phase B: rules fire, deterministically (0.4.0)

**The rule layer (spec §5).** `on :source, guard: ->(e) { ... } do |e| ... end`
— both spellings, one triple — loads through the same deny-by-default
walker, now with a second, wider mode for rule expressions: exactly-|e|
blocks and guard lambdas, `next!`, event access (`e.field`, `e[:field]`),
the §6 operator set, static `match?`, and bounded templates in both spellings
(`%{field}` against event fields and facts, `"#{e.field}"` through the
same whitelisted interpolation). The escape hatches stay shut inside guards
by name — `system`, `send`, `instance_eval`, `format`, `pack`, `extend`
and friends are a written deny list, because the file's guarantee is
analyzability, not adversarial sandboxing. World-mode files are untouched:
a lambda or a receiver call outside a rule is still a load error.

**Rules are data before they are behaviour (§5.2/§5.4).** Sources classify
against the declared world — channels, schedules, agent_online/offline,
mission_failed/step_failed, guard_denied; anything else is a load error.
Action targets are validated twice: a load-time dry-run executes each
block once against a probe event (every field reads truthy, so every
statically reachable action is captured and checked — task targets must
sit on a declared route edge, publish targets must be declared channels,
notify levels are pinned to info/warn/error), and the engine re-validates
every action at run time, so a branch the probe never took is refused at
the moment it would otherwise execute. Nothing undeclared ever runs.

**The engine (§5.3) is hermetic by construction.** It owns no thread and
no clock loop: the daemon will call `tick`; tests call `dispatch` and
`receive` directly. Semantics, exactly: rules fire in declaration order,
all matches, actions in rule order; a guard or body that raises is a
`rule_guard_error` refusal event, never a silent skip; every action
carries a deterministic request id — SHA-256 over (fleet, rule, event,
ordinal), the event id itself a digest of (source, payload) — claimed in
the `RequestLedger`, so a redelivered event cannot execute the same action
twice; beyond `max_actions_per_event` the whole event fails to the
declared dead_letter channel. `task` lowers to the addressed A2A envelope
peers already consume on `runes/agents/<id>/tasks`; `publish` writes the
channel topic with `:now` pinned to receipt time (never wall clock inside
guards); `notify` feeds the telemetry sink behind a rescue — a broken sink
must never break the fleet. Schedules are cron (five fields, `*/n`, names)
and fire only when ticked at a matching minute. The journal is an
in-memory array of structured entries today; persisting it is daemon
wiring, and the determinism certificate is already testable: two fresh
engines, same event, byte-identical request ids.

Suites: parent **730 / 4660 / 0** (`scripts/receipts.rb --suites`
re-measures).

## Phase 37 — The Fleet DSL, phase C: conformance, wiring, and 0.4.0 (0.4.0)

**L2 — auditable (§8/§11).** The policy, ACL and topology extracts of the
example fleet (`examples/prospection.fleet.rb`, the same file operators can
run and the suite tests) are golden-file diffed on every suite run, with
`scripts/fleet_golden.rb` as the intentional regeneration path; the
fingerprint of the whole analysed world sits in the golden and in the
engine's `fleet_boot` journal record, so a journal can always be tied to
the exact fleet that produced it. The ACL extract round-trips through the
real renderer: `bin/runes-acl --fleet FILE` auto-adds the fleet's roles as
first-class broker users, merges the route-edge grants into their
sections, prints the fleet digest in the header, and fails closed both
ways — a fleet grant for a role that is not an agent, or an access that is
not read/write/readwrite, aborts. A rendered fleet ACL contains no
catch-all allow; the test says so.

**Wiring.** `Fleet::Runner` wraps the engine with the process concerns it
deliberately does not own: a timer thread that calls `tick`, a JSONL
journal sink (boot record first, one entry per line, `tail`-able), and
idempotent start/stop. `bin/runes-daemon --fleet path.fleet.rb` loads the
world after connect — a bad file is loud in the log and leaves nothing
half-wired — and the runner stops before the transport disconnects. The
engine gained a mutex around journal commits (dispatches arrive on
transport reader threads AND the timer thread) and the sink is fail-safe:
a journaling error is warned about once and dropped, never fatal.

**Spec corrections while wiring.** Two more draft-spec bugs met the
compiler: §5.4's "task target on a declared route edge" made §12's own
example unloadable (the scraper has no incoming edge), fixed by declaring
the intended channel→role edge (`route :contact_found, :scraper`) and
saying in §5.4 that this is how an event source authorizes tasking a role;
and the ACL extract now grants only role-sourced edges — a channel-source
edge authorizes the fleet runtime, which publishes under its host agent's
ACL, a distinction the daemon's fleet-user story will complete. Also
recorded: Prism spells the regexp node `RegularExpressionNode` in current
versions, and a fleet file is a single source of truth — the example IS
the fixture.

**0.4.0.** Version bumped; README status, fleet section (now with the two
commands to run one) and roadmap updated; STATE.md's resume block
rewritten around the fleet layer.

Suites: parent **739 / 4700 / 0** (`scripts/receipts.rb --suites`
re-measures).

**Post-0.4.0 (2026-10-01):** filed on the official spinel repo — [#6740](https://github.com/matz/spinel/issues/6740) (required-file `IO::Buffer` `NameError`, live two-file repro) and [#6741](https://github.com/matz/spinel/issues/6741) (by-value accumulator + analysis-time ivar folding, shape-dependent observations); the `:U64` row was withdrawn (spinel matches CRuby there). Details: `docs/spinel/spec-tier-a.md`; repros: `tmp/spinel-repros/`.

## Phase 38 — The L3 gate: fleet files compile and run under Spinel (0.4.0)

**What landed.** `test/spinel_fleet_gate_test.rb` compiles every
`examples/*.fleet.rb` whole-program under Spinel against a minimal
declaration stub (`test/fixtures/fleet/spinel_gate_stub.rb`) and runs the
binary: `FLEET GATE OK` or failure. Non-blocking per spec §11: a compiler
refusal SKIPs with the refusal message; a wrong build fails — a silent
wrong answer is never skipped. The stub is deliberate about its
vocabulary: an event field used in a guard that `FleetGateEvent` does not
declare is a gate failure, extended on purpose. The stub stands in for
the real loader, which stays CRuby-only (Prism + `instance_eval(string)`
are outside Spinel's surface); compiled kernels bake the loaded world —
the workflow pattern.

**Verified on current master.** Spinel updated to f2ddd72d0
(2026.09.12+4528, 983 commits past the previous pin): the kernel
self-checks 70/70 natively — now **without** the IO_BUFFER_PROBE
workaround, fixed upstream in 3a5fccc73 (#6740 confirmed) — and the old
`<<`-style emitters also pass, matching the #6179-area fixes matz
described. The example fleet compiles and runs clean under the gate.

**Two new divergences filed** as
[matz/spinel#7213](https://github.com/matz/spinel/issues/7213), each with
a minimal two-file repro found by shrinking the gate: `instance_exec`
with a *lambda* compiles but raises NoMethodError at runtime (the plain
`&block` form works), and a block forwarded through a method's `&block`
parameter resolves bare calls to the top-level def instead of the
instance_eval receiver's instance method (literal blocks resolve
correctly). The stub works around both.

Suites: parent **740 / 4707 / 0, 0 skips** with SPINEL set (the kernel
build + fleet gate skip cleanly without it — `scripts/receipts.rb
--suites` re-measures).

## Phase 39 — Fleet hardening: schemas, shared runners, transitions, an identity (0.4.x)

**Declared payload schemas (spec §4.3).** `schema :contact, { "required"
=> ..., "fields" => {...} }` declares a literal contract (string / number /
integer / boolean / array / object); a channel naming an undeclared schema
is a load error, declaration order stays free. The engine validates before
any rule guard sees an event: a missing required field or a wrong kind is
refused to the dead-letter channel with the reason — never a rule firing
on garbage. The example fleet declares and enforces both its contracts.

**One runner per fleet.** Rule sources now subscribe under the fleet's
`group`, so N runners serving one fleet split events through the
transport's shared-subscription semantics instead of double-firing; the
per-process ledger then suffices for idempotency (the suite proves two
runners share four events exactly once each). Schedules stay the
documented exception: tick runs on every runner, so the timer belongs on
one of them.

**Presence is a transition (spec §5.2).** Retained card replays seed the
state map but never fire; unchanged live status never fires; only real
changes do. A fleet restart no longer re-notifies every online agent.

**The fleet's broker identity.** The loader's dry-run now RECORDS what
rules reach — the channels they publish to, the roles they task — and the
world derives `runtime_user` (`fleet-<name>`) plus a write-only grant list:
task topics, rule channels, dead-letter, nothing else, no catch-all.
`bin/runes-acl --fleet` renders that identity as its own user section.
The probe event grew a plausibility map (`email` looks like an email,
`score` is numeric) because guards must be *passed*, not merely typed, to
reach actions; guards the probe can't satisfy stay engine-enforced.

Suites: parent **747 / 4750 / 0, 0 skips** with SPINEL set.
