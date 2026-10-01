# Code + docs review — 2026-09-30

Review of the full tree: core library read file-by-file (~30 files, ~9k lines),
main docs, both test suites run live.

**Verification status at review time:**

- Parent harness: **640 runs / 2889 assertions / 0 failures / 0 errors**
  (`bundle exec rake test`)
- Observatory: **219 runs / 1085 assertions / 0 failures / 0 errors**
  (`cd runes_observer && bin/rails test`)

**Overall verdict:** no critical or high-severity code defects. Fail-closed
defaults, defense-in-depth, and an honest "Known limitations" list that matches
the code. The actionable findings are documentation drift plus a handful of
low/nit items.

---

## Findings

### Medium — documentation

1. **`docs/SECURITY.md` threat model is stale on envelope replay**
   (lines 45–51 and 389–391). It states signed prompt envelopes "carry no
   timestamp/nonce" and lists replay protection as out of scope. That is no
   longer true: `doc5.md` E5-13 implemented freshness — `Fabric#delegate_to`
   signs with `fresh: true`, `Fabric#verify_signed!` passes a process-wide
   `REPLAY_GUARD` (`Runes::Security::NonceCache`), and
   `Envelope.check_freshness!` enforces the age window and consumes the nonce
   after verification. A captured envelope replayed inside the window is now
   refused with `:replayed`.
   **Fix:** move the item from "Out of scope" to "In scope", noting it is
   mandatory with `RUNES_REQUIRE_FRESHNESS=1` and opportunistic otherwise
   (envelopes carrying ts/nonce are checked even when the env var is unset).

2. **`RUNES_REQUIRE_FRESHNESS` is undocumented.** Read by the dispatcher
   (`lib/runes/core/dispatcher.rb`) but absent from the README configuration
   table, `config/.env.example` and `docs/SECURITY.md`. It exists only in code
   comments. Users cannot discover the stricter freshness mode.
   **Fix:** add one row to the README table and one commented line to
   `.env.example`.

3. **`RUNES_TOOL_CONCURRENT` is missing from the README configuration table.**
   It is honoured by the dispatcher (`max_tool_concurrent`, default 2) and
   documented in `config/.env.example`, but not in the README table.

4. **Quoted test counts have drifted / disagree with each other.**
   - `docs/WHY_RUNES.md` quotes both "600 tests, 2 696 assertions" (line 136)
     and "636 runs, 2 879 assertions" (line 267) as current in the same
     document. Live numbers at review time: **640 runs / 2889 assertions**.
   - `STATE.md` quotes 636/2879 (dated 2026-09-10 — acceptable) but line 118
     quotes 527/2419 with no clear date separation from the 636 block.
   - `DEVELOPMENT_LOG.md`'s header "**Where this stands now**: … **258 runs /
     1059 assertions**" is ~7 phases stale.
   **Fix:** per STATE.md's own rule, re-measure with
   `ruby scripts/receipts.rb --suites` and paste, never remember; retitle the
   DEVELOPMENT_LOG header with its phase number so it reads as a snapshot.

### Low — code

5. **Busy-reply is broadcast fleet-wide** (`Dispatcher#dispatch_prompt`). When
   the prompt queue saturates, the refusal publishes to the *global*
   `runes/prompts/response` because the dispatcher cannot know the requester's
   reply topic. Functionally fine (a saturated queue must answer loudly), but
   every fleet client sees another client's backpressure. Not worth changing
   unless it becomes noise.

6. **`run_confined` can still spawn `/bin/sh`.** Any surviving fd-redirect
   (`2>&1`) makes Ruby's `Process.spawn` treat the command string as needing a
   shell. The spawned shell is still confined (workspace `chdir`,
   `unsetenv_others` + scrubbed env, vetted text — no separators,
   substitutions or other redirections survive the policy), so this is a
   comment-level clarification, not a hole: the "no shell" mental model is not
   literally true on that one path.

7. **Workflow `Runes::CommandRunner` captures stdout/stderr unboundedly.**
   Unlike the dispatcher's `run_confined` (which honours
   `RUNES_CMD_OUTPUT_CAP`), the workflow-side runner buffers everything in
   memory. A chatty or long-running `cmd` step can grow RAM without limit.
   Roast-compatible behaviour, but a `cap:` option would close it.

8. **`InProcess` group round-robin cursor is keyed by group name only**, not
   by `(group, filter)`. Two subscriptions sharing a group name with different
   filters would share a cursor. Harmless for current usage (one group, one
   filter), but the reference implementation of the contract should key on
   both.

### Nits

9. `TrustStore#key_for` matches agent id *or* fingerprint — a 64-hex agent id
   could alias a fingerprint lookup. Negligible.
10. `DEVELOPMENT_LOG.md`'s "Where this stands now" header reads like a current
    summary; retitle to "Snapshot at 2026-09-10 (Phase 15)".
11. Untracked files in the working tree: `docs/2609.20804v1.pdf` and `models/`
    (a 9B model + weights README). Fine if intentional, but neither is in
    `.gitignore`, so `git status` stays dirty.

---

## Checked and found sound (highlights)

- **Guard** (`lib/runes/capabilities/guard.rb`): fail-closed on nil
  tool/action/resource, on malformed fragments, and on an unreadable policy
  file (S5-3: nothing is granted, not even the builtin baseline). Manifest
  fragments are additive-only for builtins. One shared `TopicFilter` for
  guard/broker/hub — no regex divergence.
- **CommandPolicy**: metacharacter block with the `2>&1` exemption, launcher
  following (`timeout 5 ruby -e …` is still caught), interpreter/privileged
  refusal unless explicitly allowlisted, `--opt=/abs/path` splitting,
  `~`/absolute/`..` rejection, unclassifiable tokens fail closed,
  `./env ruby …`-style tricks die on the final command-name check.
- **Envelope / RPCAuth / NonceCache**: canonical form (sorted keys, strict
  value types, duplicate-key rejection after `to_s`), freshness checked only
  after signature verification, nonce consumed only for verified payloads,
  strict base64 decode, constant-time compares, bounded TTL'd caches, empty
  trust store fails closed (`:unknown_key`), `TrustStore.permissive` still
  requires a real key.
- **Dispatcher**: signature gate runs *before* the ledger claim (documented
  ordering — no poisoning unverified ids), `safe_path` rejects NUL/absolute/
  `..` and resolves the deepest existing ancestor against the workspace
  realpath, atomic mission sidecar writes (tmp + rename), env scrubbing with
  `unsetenv_others`, process-group kill on timeout, output cap, byte-safe
  prompt truncation.
- **MQTT5 codec + embedded broker**: varint bounds, full property-type table
  so unknown ids skip correctly, 16 MiB packet cap, QoS 3 rejected as
  malformed, write deadlines (T5-3), keepalive grace (T5-2), reconnect with
  resubscribe; broker honours CONNECT-first, retained count *and* byte budget,
  QoS 2 dedup, per-client subscription caps, time-boxed body reads, wildcard
  Will/PUBLISH rejection — matching the "dev-grade, localhost only" claims.
- **LLM router**: total retry wall-clock budget, capped Retry-After honouring,
  provider error bodies sanitized and bounded before reaching MQTT/journal,
  malformed tool-call arguments fail closed (never executed as empty args),
  `finish_reason=length` surfaced as an explicit error.
- **RequestLedger**: mutex-atomic claim, single TTL for the whole ledger,
  insertion-order eviction, bounded.
- **Journal**: cross-process `flock`, timestamped rotation archives,
  JSONL append, `RUNES_REDACT_PROMPTS` opt-in redaction.
- **VMManager**: fuel budget plus epoch wall-clock deadline, mock results
  explicitly marked so demos never masquerade as real executions.
- **ToolRegistry**: tool-name charset constraint (names become topic
  fragments), symlinked tool dirs rejected, manifest size/nesting caps,
  drift logging between scans.
- **Workflow engine**: rune DSL methods bound on a fresh `ExecutionContext`
  per scope, `TaskGroup` cleanup in `ensure` that never masks in-flight
  exceptions, per-step timeout checks, `CommandRunner` never spawns a shell
  by default (one-element argv spawned as `[cmd, cmd]`) and serializes the
  Bundler env swap (W5-6).
- **Kanban / DocStore / Index**: flock'd read-modify-write, model-output title
  sanitizing (no forged checkboxes/assignee suffixes), validate matching the
  external `validate_mermaid.rb` contract.
- **Fabric**: single `admitted_payload` gate so future subscription paths
  cannot forget signature verification, reply-topic whitelist (no wildcards,
  no `$`, no empty levels, bounded length), peer replies sanitized and
  bounded, peer ids grammar-checked before entering peer state.
- **Settings**: dotenv values kept out of the process ENV (S-R1), real ENV
  wins, SQLite `busy_timeout` + WAL, read-only DB tolerated at boot.

---

## Suggested next actions (in order)

1. Update `docs/SECURITY.md` §1 (move envelope replay to in-scope, describe
   the `RUNES_REQUIRE_FRESHNESS` knob).
2. Add `RUNES_REQUIRE_FRESHNESS` and `RUNES_TOOL_CONCURRENT` to the README
   configuration table; add both to `config/.env.example` comments.
3. Re-measure: `ruby scripts/receipts.rb --suites` → paste into WHY_RUNES.md,
   STATE.md; retitle the DEVELOPMENT_LOG header with its phase.
4. Optional code follow-ups: output cap for the workflow `CommandRunner`;
   `(group, filter)` cursor key in the in-process hub.
