# Runes Development Log & Plan

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
