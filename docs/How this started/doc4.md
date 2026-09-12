# Runes — Code Review, Round 4: Flaws & Proposed Enhancements

**Scope.** Full reading of `lib/runes/**` (dispatcher, llm_client, plan_parser,
settings, tool_registry, mqtt/broker, wasm/vm_manager, capabilities/guard),
`bin/*`, `config/`, `test/`, plus the shipped `config/.env`. Every finding below
was reproduced against the tree as it stands (2026-09-10), not inferred from the
docs.

**Relationship to `doc.md`.** `doc.md` is the round-3 audit (D1–D11, L1–L7,
R1–R5, M1–M11, W1–W6, T1–T9, S-*). This document does **not** repeat those.
Identifiers here are `B4-*` / `S4-*` / `T4-*` / `E4-*`. Where a finding is an
incomplete fix or a new angle on a round-3 item, it says so.

> **Status: all findings below are FIXED and all enhancements implemented**
> (2026-09-10, Phase 14 — see `DEVELOPMENT_LOG.md`). Suite: **258 runs /
> 1059 assertions / 0 failures / 0 errors / 0 skips**, hermetic and fully
> offline (no live API keys; provider HTTP is faked with a dup transport),
> and stable across seeds 1 / 5 / 7 / 4242 / 99991 / 31337 / 20260910. DeepSeek V4.1
> Flash (`deepseek-flash`, reasoning effort high) is now the preferred
> provider ahead of Synthetic and Cerebras, and was validated against the
> live API: a direct call (1.5 s, reasoning tokens present) and
> `demo/hello_world_live.rb` (**ALL CHECKS PASSED, 3.1 s** — plan →
> write ×2 → run the generated minitest green). That live run found the
> additional **B4-14** below. The TUI findings T4-1…
> T4-10 are fixed with 23 new regression tests. Two items were
> deliberately narrowed rather than adopted verbatim: `RUNES_CMD_ALLOWLIST`
> stays opt-in (it would break the shipped live demos, and path
> containment now covers the reported escapes), and `rake docs:check`
> (E4-13) was replaced by making the docs state the real, freshly measured
> numbers. One additional hermeticity bug found while fixing B4-13 —
> `test/cli_tools_test.rb` wrote to and deleted the *developer's* real
> `log/journal.jsonl` — is fixed too (`bin/runes-replay` now honours
> `RUNES_ROOT`). The findings text below is the original review, kept as
> the record of what was wrong.

---

## 0. Headline

Four things deserve attention before any feature work:

1. **The suite is not green.** `bundle exec rake test` gave **three different
   outcomes in three runs** (failure / error / error+skip) at the same commit.
   README and STATE both claim `202 runs, 532 assertions, 0 failures`.
2. **The shipped config cannot reach any LLM.** `config/.env` contains a
   `DEEPSEEK` key; `LLMClient::PROVIDERS` knows only `cerebras` and `synthetic`.
   `resolve_route` returns `nil` → every live demo and the live test are dead
   until a DeepSeek provider is registered.
3. **The tool-RPC topic is an unauthenticated remote-execution endpoint.** Any
   client that can reach the broker can run arbitrary commands as the daemon
   user (PoC below).
4. **The broadcast claim protocol does not guarantee one winner.** Two agents
   executed the *same* broadcast prompt in a verified two-agent PoC.

---

## Bugs

### B4-1 — Test suite is red and order-dependent (severity: high)

Observed across four runs of the same tree:

| run | result |
|---|---|
| `rake test` | `202 runs, 1 failures, 0 errors, 0 skips` — `TestLLMRouter#test_live_synthetic_glm_call`: `synthetic request failed: TypeError: String does not have #dig method` |
| `rake test` (seed 5407) | `202 runs, 529 assertions, 0 failures, 1 errors, 1 skips` — `TestCliTools#test_replay_rejects_negative_last`: `IOError: stream closed in another thread` |
| `rake test TESTOPTS="--seed=5407"` | identical to the previous row (so it is reproducible **at that seed**, not merely random) |
| `rake test` | live test skipped (the README's "green" case) |

Two independent defects:

- **Live test fires on a stray key, and its failure is masked.** `test/llm_router_test.rb:180-195`
  calls `Dotenv.load(Settings::ENV_PATH)` (which mutates the global `ENV` and is
  never undone) and gates the network call only on
  `ENV['SYNTHETIC'] || ENV['SYNTHETIC_API_KEY']` being non-empty. There is no
  explicit "I intend to hit the network" opt-in, and the assertion is reached
  with whatever key happens to be visible. When that call does happen against a
  non-working key, the 401 exposes B4-2 and the test fails rather than skips.
  The exact trigger for run 1 could not be reproduced on demand (four later
  runs skipped it, and the per-test `ENV` save/restore at
  `llm_router_test.rb:12-14,30-32` is correct in isolation), which is itself the
  problem: the suite's red/green outcome depends on state outside the test's
  control.
- **Pipe-reader race.** `test/cli_tools_test.rb:43-47` spawns threads that
  `read` the child's pipes; the main thread then closes those pipes and `join`s
  the readers. If a reader is still blocked in `read`, the close raises `IOError`
  inside it, and `Thread#join` re-raises it as a test error. Deterministic at
  seed 5407, absent at others — a timing/load dependency.

The assertion total also drifts between runs (532 → 533 → 529) because the live
test sometimes skips, sometimes runs.

Across **7 full runs** in total: 5 green (`202 runs, 532 assertions, 1 skip`),
1 failure (live test, run 1), 1 error (`cli_tools` pipe race, reproduced at
`--seed=5407` and again at `--seed=14936`). Two of seven is not "flaky enough to
ignore" — it is a suite whose result depends on machine load, and every finding
below is a change that would land on top of a possibly-red baseline.

### B4-14 — Duplicate tool names made the default planner request invalid (severity: high)

**Found by live validation against DeepSeek after the other fixes.**
`tools/` ships manifests for the builtins (`write_file`, `read_file`,
`run_command`) as well as `echo`, and `Dispatcher#tool_schemas` turned
*every* registry card into an OpenAI tool schema on top of
`builtin_schemas`, so four of the five names appeared twice. DeepSeek
rejects that with `HTTP 400: Tool names must be unique` — every
function-calling build prompt failed. Synthetic/GLM had tolerated the
duplicate, which is why three rounds of live demos never caught it.

Fixed in two layers: `tool_schemas` skips registry cards whose name is a
builtin, and `LLMClient.builtin_schemas` dedupes `extra` against the
builtin names (so a caller cannot reintroduce it). Regression test added
to `test/fourth_audit_test.rb`.


`lib/runes/core/llm_client.rb:382`

```ruby
msg = parsed.is_a?(Hash) ? (parsed.dig('error', 'message') || response.body) : response.body
```

`Hash#dig` raises `TypeError: String does not have #dig method` when
`parsed['error']` is a String — which is what many OpenAI-compatible gateways
(and the Synthetic 401 that produced the failing test) return. The `TypeError`
is swallowed by the method's blanket `rescue => e`, so the operator sees
`synthetic request failed: TypeError: ...` instead of `HTTP 401: <message>`.

Reproduced (`tmp/repro_dig.rb`):

```
{"error":"invalid api key"}          -> "synthetic request failed: TypeError: String does not have #dig method"
{"error":{"message":"invalid api key"}} -> "synthetic HTTP 401: invalid api key"
```

This is *not* S-L1 (round 3, which sanitized the body) — that fix is defeated
before it runs. Any provider error that is a bare string, list, or number hits
this.

### B4-3 — The claim protocol's single-winner guarantee fails under saturation (severity: high)

`lib/runes/core/dispatcher.rb:276-300` — when `@in_flight >= max_concurrent_prompts`
the prompt pipeline runs **inline on the reactive loop**:

```ruby
unless take_slot
  log 'Concurrency cap reached; processing prompt inline.'
  return blk.call          # claim race + sleep + LLM call, all on the loop
end
```

But `MQTT::Client#get` yields each packet **in the calling thread** (verified in
the gem: `def get` → `get_packet` → `yield`). While the loop is inside the inline
handler it cannot read the peer claims that arrive during the 0.6 s window, so
`claims_for` (`dispatcher.rb:506`) returns only the agent's own claim and
`claims.min == @agent_id` (`dispatcher.rb:446`) is true for *every* saturated
agent. `begin_execution?` (`dispatcher.rb:533`) is per-process, so it cannot
dedupe across agents.

Reproduced with two dispatchers, `RUNES_MAX_CONCURRENT=1` (`tmp/poc_dup.rb`):

```
agents on the bus: aaa-agent, zzz-agent (RUNES_MAX_CONCURRENT=1)
planner runs for FIRST : 1
planner runs for SECOND: 2
   run 1: agent=zzz-agent
   run 2: agent=aaa-agent
VERDICT: the SAME broadcast was executed by 2 different agents
```

A second, even without a slow planner: a prompt that arrives while agents are
inside *another* prompt's 0.6 s claim window (`@in_flight` still counts the
claim-window worker) takes the same inline path, and every claimant
self-declares victory. The 2.0 s staleness grace in `claims_for` is far shorter
than a real planner call (up to 180 s), so delayed-but-honest claimants also
re-enter the race after the winner already ran. This defeats the property
README (`…exactly one agent executes each build prompt…`) is built on.

### B4-4 — `extract_json_object` is brace-blind, so valid missions are rejected (severity: medium)

`lib/runes/core/dispatcher.rb:1073-1095` scans for the closing brace by counting
`{`/`}` **without tracking string literals**. `PlanParser#matching_brace`
(`plan_parser.rb:78-102`) was fixed for exactly this in round 3 (L1); the
dispatcher's copy was not.

`JSON.parse(text)` handles the pure-JSON case, so this only bites when the model
wraps the object in prose/fences — which is the common failure the fallback
exists for. Reproduced (`tmp/verify2.rb`):

```
"use { in the title"  -> nil  <-- mission REJECTED
"use } in the title"  -> nil  <-- mission REJECTED
balanced "a {b} title" -> parsed
css "body { color: red }" -> parsed
```

Result: one re-ask burned, then `/plan` fails loud with "no mission file
written" on a perfectly valid todo list. It also returns `nil` for any string
that merely *contains* a brace before the JSON.

### B4-5 — Mission steps silently bypass the default planner path (severity: medium)

Build mode uses native function calling by default (`dispatcher.rb:745`), but
`execute_mission_step` calls `@llm.call(step_prompt)` with **no `tools:`
argument** (`dispatcher.rb:1269`). Consequences:

- Every `/build <mission>` todo uses the legacy free-form JSON path, so the
  advertised default (`RUNES_USE_TOOLS` on, "live-validated" by
  `demo/tool_calls_live.rb`) is never exercised by the mission executor.
- Tool *schemas* are not sent either, so manifest tools registered in `tools/`
  are invisible to the mission planner while they are visible to build mode.
- It also means `RUNES_USE_TOOLS=0` has no effect in the mission path.

### B4-6 — The QA verifier never sees the evidence it is asked to judge (severity: medium)

`summarize` truncates each step outcome to **200 characters**
(`dispatcher.rb:1519`), and `verify_mission_step` then truncates that whole
summary to **2000 characters** (`dispatcher.rb:1313`). The verifier is prompted
to "judge ONLY on the stated evidence", but the `read_file` evidence the planner
was explicitly told to produce arrives as a 200-char fragment; a multi-step todo
loses everything past the first few steps. This is a fail-closed gate on
starved input, so good work is rejected and the mission stops (default
`RUNES_MISSION_CONTINUE` unset).

### B4-7 — Journal rotation loses entries when more than one process appends (severity: medium)

`dispatcher.rb:1496-1513`. `@journal_mutex` is per-process; the file is shared
by design (daemon + CLI, and the two-dispatcher lease scenario the project
tests). `rotate_journal` does `File.rename(path, "#{path}.1")` — uncoordinated
across processes, so two rotators can clobber the same `.1` (silent loss of up
to 10 MiB of audit trail), and a writer that has the old inode open keeps
appending to the renamed file. An audit journal that silently drops records is
worse than none.

### B4-8 — `write_file` cannot create or truncate an empty file (severity: low)

`dispatcher.rb:1614`: `return 'Error: invalid args' if path.nil? || content.empty?`
conflates "missing content" with "empty content". A planner that legitimately
needs `touch`-semantics (placeholder, `.gitkeep`, clearing a file) gets an
error, and the error text points at the wrong cause. Reproduced: writing
`content: ""` → `"Error: invalid args"`.

### B4-9 — `RUNES_WASM` / `RUNES_WASM_TIMEOUT_S` bypass `config/.env` (severity: low)

`vm_manager.rb:205` and `:226` read `ENV[...]` directly. Every other `RUNES_*`
setting goes through `Settings#env` (real ENV **or** `config/.env`). So
`RUNES_WASM=real` placed in `config/.env` — which the README's config table
invites — is silently ignored and the mock backend is used. Either honour
`config/.env` here or document "these two must be exported".

### B4-10 — Prompt truncation mixes bytes and characters (severity: low)

`dispatcher.rb:736-740` compares `prompt.bytesize > MAX_PROMPT_BYTES` but then
truncates with `prompt[0, MAX_PROMPT_BYTES]`, which is a *character* slice. For
multibyte input the "truncated" prompt can still exceed the cap (up to ~4×),
and the `prompt_truncated` event is emitted for a prompt that may not need it.
Same pattern in `handle_goal_turn`/`handle_plan`.

### B4-11 — Broker protocol gaps (severity: low)

- **QoS 2 is at-least-once, not exactly-once.** `handle_publish`
  (`broker.rb:417-419`) fans the message out at PUBLISH time, returns PUBREC,
  and never records the packet id; a DUP retransmission is delivered again and
  `handle_pubrel` just replies PUBCOMP.
- **No CONNECT required.** `handle_client` (`broker.rb:213-256`) accepts
  PUBLISH/SUBSCRIBE before CONNECT, so the connection caps can be exercised by
  clients that never identify themselves.
- **Will topics are not validated.** `handle_connect` (`broker.rb:296-317`)
  accepts `+`/`#` in the Will topic, which MQTT 3.1.1 forbids and which then
  flows into `wire_and_retain` as a publish topic.

### B4-12 — Documentation drift (severity: low)

- `README.md:14` claims `202 tests / 532 assertions green`; false today (B4-1).
- `README.md:289` says `test/ 152-test suite`; `STATE.md:94` says `12 test
  files, 152 examples` and `:236` says `152/412`. Actual: 202/529–533.
- `README.md:84-85` and `STATE.md:61-62` say the live `.env` routes to
  Synthetic GLM-5.3-Flash; the file now contains a DeepSeek key (S4-3 / E4-1).
- `STATE.md:242` (runbook) still references `bin/rakes-replay` as a fallback.

### B4-13 — The suite is not hermetic: it writes into the project tree (severity: low)

**Found during the fix round, not in the original review:** two tests in
`test/cli_tools_test.rb` wrote a fixture journal to the *developer's*
`<project>/log/journal.jsonl` and deleted it in `ensure`, destroying the
real audit trail on every run; `bin/runes-replay` also hardcoded the
project root, so it could not be aimed elsewhere. Found by a sentinel +
per-file bisect. Fixed: `bin/runes-replay` honours `RUNES_ROOT`, and the
tests use their own tmp root.

`log/journal.jsonl` was created/updated (mtime `09:04`) by the test runs
themselves. Several suites build a real `Runes::Core::Settings.new` with no
temp `root` (e.g. `dispatcher_safety_test.rb:9`) and exercise
`record_prompt_log`, so the durable journal of the *developer's* project is
appended to on every `rake test`. Two developers (or two CI jobs) on one
checkout interleave writes into the same audit file, and `runes.db` is shared
too. Tests should point `Settings` at a temp root, or the journal path should be
injectable.

---

## Bugs in the TUI (`bin/runes`)

A focused pass over `bin/runes` (756 lines) produced these; all are new relative
to `doc.md`'s T1–T9 (T1/T4 are fixed in this revision). Items T4-1…T4-7 and
T4-9 were reproduced by driving the real methods; T4-8/T4-10 are read directly
off the cited lines. I re-verified T4-1, T4-2, T4-5 and T4-4 at the source.

### T4-1 — Non-object JSON in any subscribed topic crashes the reader into a reconnect loop (severity: high)

`bin/runes:167-169` and `:187-188`. `JSON.parse(message) rescue {}` only catches
*parse* failures: `"[]"`, `"null"` and `"5"` are valid JSON, so `card['tools']`
and `evt['event']` then raise `TypeError`/`NoMethodError`. The exception escapes
`handle_event`, unwinds `client.get` (`:140-143`), and is swallowed by the
`rescue StandardError` in `run_reader` (`:145`) → disconnect, reconnect, repeat.
Because agent cards are published **retained** (`dispatcher.rb:182`), a single
retained `[]` card is redelivered on every resubscribe: the TUI reconnects
forever and never processes another event. Any publisher on the broker can do
this — and per S4-1, anyone who can reach the broker is already trusted with
worse.

### T4-2 — Invalid UTF-8 topic names crash before sanitization (severity: high)

`bin/runes:164`. The mqtt gem force-encodes PUBLISH topic names to UTF-8
without validating, and the bundled broker only rejects wildcards/empty topics
(`broker.rb:427-434`). Matching the ASCII regexps in the `case topic` at `:164`
against a topic containing `\xff` raises `ArgumentError: invalid byte sequence
in UTF-8` — before `sanitize` at `:162` can help — with the same permanent
reconnect loop as T4-1.

### T4-3 — Reader backoff is reset by a *successful connect* (severity: medium)

`bin/runes:132` sets `delay = 0.5` immediately after `MQTT::Client.connect`
returns, i.e. before subscribing or consuming. Every post-CONNECT failure
(T4-1/T4-2, or the broker dropping the socket) therefore retries at 0.5 s
forever; `LIMITS[:reader_retry_s]` (3.0) is never reached. The reset belongs
after the subscribe/consume boundary.

### T4-4 — `traffic_notice` never trims `@traffic` (severity: medium)

`bin/runes:557-562` appends without the `shift while size > limit` used by the
other two producers (`:229`, `:425`). It is called once per reader reconnect —
twice per second under T4-3 — and on every publish failure, so the array grows
without bound while the draw thread `dup`s it every frame. Topic-derived ids in
traffic lines are also unbounded (`:182`, `:226`).

### T4-5 — `sanitize` lets LF/TAB through, so payloads can paint outside their panel slot (severity: medium)

`bin/runes:65` defines `CONTROL_CHARS = /[\x00-\x08\x0b-\x1f\x7f]/`, which
deliberately omits `\x09`/`\x0a`. The status branch stores the raw sanitized
payload and copies it into a traffic line (`:174-175`), and traffic lines are
rendered verbatim at `:682` with no whitespace collapsing. A status payload
containing newlines walks the cursor down and prints a forged Traffic row on a
line the renderer never clears. The Registry panel is unaffected
(`display_safe`, `:634-637`), so this is specifically the S-T1 guarantee
failing on the path it was added for.

### T4-6 — Pasted/piped input is rendered to the terminal unsanitized (severity: medium)

`bin/runes:329-353`, `:279-287`, `:403-407`, `:697-699`. `sanitize` is applied
only to broker messages; `read_paste` keeps ESC and friends, `insert_text`
stores them in `@input`, and `compose_frame` prints `@input` verbatim. A pasted
OSC 52 sequence is emitted byte-for-byte (clipboard write). The non-tty `gets`
path has the same hole.

### T4-7 — Bracketed-paste cap abandons the paste mid-stream (severity: medium)

`bin/runes:339-343`, `:347-352`. On exceeding `LIMITS[:paste_bytes]` (or a
missing terminator) the loop breaks without draining to `PASTE_END`, so the
remainder is re-read as keystrokes — including `\r` → `:enter` →
`submit_buffer`. Reproduced with a 64,001-byte body: 13 bytes (two Enters plus
the terminator) are left queued. A large paste can auto-submit partial content.

### T4-8 — `publish_envelope` blocks the input thread on connect (severity: low)

`bin/runes:571-577`. The first publish, and the first after any failure, does a
synchronous connect (30 s connect timeout plus CONNACK wait) on the keystroke
thread, so submitting against an unreachable broker freezes the UI — including
Ctrl+C — for ~30 s.

### T4-9 — Traffic/input truncate by characters, not display columns (severity: low)

`bin/runes:682`, `:699`. `display_safe` is applied to the Registry panel only;
CJK in a traffic line or the input row wraps into the adjacent panel. Same
class as T5, which was fixed for the Registry but not here.

### T4-10 — A fallible write before `stop` in `run_input`'s `ensure` (severity: low)

`bin/runes:254-266`. The `ensure` prints the bracketed-paste reset before
calling `stop`; a write error on a dying tty (not catchable by the method's
`rescue`) skips `stop`, leaving the input thread dead while `@running` stays
true.

---

## Security findings

### S4-1 — Unauthenticated remote command execution via `runes/tools/+/request` (severity: critical)

The dispatcher subscribes to `runes/tools/+/request` (`dispatcher.rb:139`) and
routes builtin tool ids straight to `execute_builtin` (`dispatcher.rb:1526-1538`).
For builtins the guard is checked only on the *action*
(`run_command`/`exec`) and the shipped `BUILTIN_BASELINE` grants `exec => ['#']`
(`guard.rb:29-33`) — the constructor even prints the "guard is inert" warning.
There is no authentication, no allowlist by default, and no client ACL
(README: "no authentication"). Round 3's D6 deliberately removed the
`mqtt_publish` check that used to make this branch unreachable; the branch is
now wide open.

PoC (`tmp/poc_rce.rb`) — an unrelated `MQTT::Client` with no credentials:

```
attacker published: {"cmd":"touch PWNED-BY-UNAUTHENTICATED-CLIENT"}
broker reply:       "exit=0"
file created by the command inside the dispatcher workspace: true
```

Any process that can reach `RUNES_MQTT_HOST:PORT` (default `127.0.0.1:1883`,
but the variable is free-form and mosquitto is explicitly supported) gets
command execution as the daemon user, plus `write_file` over the whole
workspace. On a shared host this is a local privilege boundary; on a LAN-bound
broker it is remote RCE.

### S4-2 — `run_command` is not confined to the workspace, and `rm -rf ..` / `rm -rf ~` pass the denylist (severity: high)

`run_in_workspace` (`dispatcher.rb:1716-1732`) relies on
`SHELL_INJECTION_CHARS` plus `DANGEROUS_COMMAND_PATTERNS`
(`dispatcher.rb:48-56`). That list only catches `rm -rf /` (literal root),
`sudo`, `mkfs`, `dd if=`, `shutdown`, `reboot`, `/etc/{passwd,shadow,sudoers}`.
`chdir: @workspace` (`dispatcher.rb:1754`) is not confinement, as the README
concedes — but the concrete blast radius is worth stating explicitly.

Reproduced (`tmp/verify_flaws.rb`), with the workspace at `<tmp>/workspace` and
a sibling directory `<tmp>/victim`:

```
dangerous_command?('rm -rf ..')  -> false
dangerous_command?('rm -rf ~')   -> false
dangerous_command?('rm -rf /')   -> true
run_in_workspace('rm -rf ../victim') -> "exit=0"
exists before: true / exists after: false   <-- sibling of the workspace deleted
```

`~` is expanded by `/bin/sh` (verified: `echo ~` → the user's home directory),
so `rm -rf ~`, `rm -rf ../../..`, `find .. -delete`, `cat ~/.ssh/id_rsa`,
`chmod -R 000 ..`, `mv ../project elsewhere` are all permitted. With the
planner-driven path there is no human in the loop. This is not "the denylist is
not a security boundary" in the abstract — it is one unencoded character
(`..`) away from deleting the project and the user's home directory.

### S4-3 — A live API key sits in a plaintext file that is one `git init` from being committed (severity: high)

`config/.env` contains an active `DEEPSEEK=sk-...` credential (35 chars), and
the project root has **no `.gitignore`** (`ls .gitignore` → not found), while
`STATE.md:243` explicitly suggests initializing git and `README.md` tells users
to copy the file. A `git add -A` would commit the key plus `runes.db`
(preferences), `log/journal.jsonl` (prompt history, S-D3), `workspace/`, and the
37 MB `ruby.wasm`. The `.env` is also the wrong place given E4-1: the key is
currently unused *and* exposed.

### S4-4 — Guard decisions use the raw argument while the write target is resolved (severity: medium)

In `execute_builtin` (`dispatcher.rb:1612-1628`) the path is resolved first:

```ruby
path = safe_path(args['path'])                    # resolved / expanded
...
@guard.allowed?('write_file', :fs_write, args['path'].to_s)   # raw string
```

The capability decision and the actual filesystem target are derived from
different strings. Today `safe_path` guarantees containment and the baseline is
`'#'`, so impact is limited — but as soon as an operator narrows the policy
(the constructor and policy.json both push them to), pattern-based rules are
matched against text that does not have to be the path written to
(`a/../b`, `./x`, trailing whitespace, case differences on case-insensitive
filesystems). `resolve_realpath_within` also returns the *lexical* `expanded`
path (`dispatcher.rb:1671`), so the check and the write can diverge under a
concurrent symlink swap — the known TOCTOU, but the guard should at least judge
the same string.

### S4-5 — Retained-message cap allows ~1 GiB, and prompt text is retained in plaintext (severity: low/medium)

`broker.rb:23-25`: `MAX_RETAINED_COUNT = 1_000` × `MAX_RETAINED_BYTES = 1 MiB`
is a 1 GiB ceiling for a "dev-grade" in-process broker. Separately,
`record_prompt_log` retains the newest entry on
`runes/_log/prompts/latest` (`dispatcher.rb:1472`), so the last prompt — up to
2000 chars, or a redaction hash under `RUNES_REDACT_PROMPTS=1` — is served to
every late subscriber. Round 3's S-D3 covers the journal; the *retained* copy
survives daemon restarts only via the broker, but it is readable by any client
that subscribes after the fact, which is the same exposure with a different
lifetime.

---

## Proposed enhancements

### E4-1 — Register a DeepSeek provider (unblocks the live path)

`config/.env` already carries the key; the registry does not. Add to
`LLMClient::PROVIDERS`:

```ruby
'deepseek' => Provider.new(
  name: 'deepseek',
  base_url: 'https://api.deepseek.com/v1',
  key_envs: %w[DEEPSEEK_API_KEY DEEPSEEK],
  default_model: 'deepseek-chat',
  seed_model: 'deepseek-chat',
  model_prefix: 'deepseek',
  aliases: { 'deepseek-v3' => 'deepseek-chat', 'deepseek-reasoner' => 'deepseek-reasoner' },
  sampling: :temperature        # or a :deepseek strategy if reasoning_effort is desired
)
```

Then: seed `default_provider` from `DEEPSEEK` (extend the seed list at
`settings.rb:131`), add the two env keys to `scrubbed_child_env`'s provider list
(automatic — it derives from `PROVIDERS`), and extend the router tests. This is
the single change that makes every live demo, the live test, and the shipped
config agree again.

### E4-2 — Make the network test explicitly opt-in and stop global `ENV` mutation

- Gate the live test on an explicit `RUNES_LIVE=1` (or reuse an existing
  convention) **in addition** to a key check, so a stray/placeholder key can
  never trigger a network call from `rake test`.
- Replace `Dotenv.load` in the test with a per-test read of parsed values
  (`Dotenv.parse(path)`) that never writes to `ENV`; add an `ENV` save/restore
  helper used by every test that touches process env (several test files set
  `RUNES_*` without cleanup).
- Run the suite with a fixed seed in the runbook (and ideally a couple of
  seeds), so the order-dependent failures in B4-1 stay fixed.

### E4-3 — Never run the claim race inline

Replace the inline fallback in `dispatch_prompt` (`dispatcher.rb:286-289`) with
one of:

- **queue** the work (unbounded-ish internal queue drained by the worker pool),
  so the reactive loop only ever records claims and routes; or
- **busy-reject** with an explicit `progress` event + response (the pattern
  already used for tool RPCs at `dispatcher.rb:317-321`), which is honest and
  keeps liveness.

If inline execution is kept for any path, the claim window must not be part of
it. Additionally, make the lease robust rather than timing-based: have the
winner publish an observable "I am executing" marker (retained, or a
`…/progress` `prompt_started` event) and have every agent verify it before
executing — a claimant that sees a `prompt_started` from a lexicographically
smaller agent stands down even if it never saw that agent's claim. That closes
B4-3 without depending on `RUNES_CLAIM_WINDOW_S` covering LLM latency.

### E4-4 — One bounded, string-aware JSON object extractor

Move the scanner into a single shared helper (e.g.
`Runes::Core::JsonScan.extract_object(text, max_bytes:, max_nesting:)`) and use
it in both `PlanParser` and `Dispatcher#extract_json_object`. Delete the
duplicate at `dispatcher.rb:1073-1095` (fixes B4-4 and prevents the next
divergence). Add the three unbalanced-brace cases from `tmp/verify2.rb` as unit
tests.

### E4-5 — Give `run_command` a real boundary (fixes S4-2)

Cheapest meaningful step, in order:

1. Reject commands whose *any* token is an absolute path, starts with `~`, or
   resolves (lexically) outside the workspace, for a denylist of destructive
   verbs (`rm`, `mv`, `chmod`, `chown`, `truncate`, `find -delete`, …). Reject
   `..` as a path token outright.
2. Resolve the command's target paths with `safe_path` before execution and
   refuse any that fail — reusing the existing containment logic instead of a
   parallel regex list.
3. Make `RUNES_CMD_ALLOWLIST` **on by default** with a small safe set
   (`ls`, `cat`, `head`, `tail`, `grep`, `wc`, `ruby`-free), and log loudly when
   it is disabled.
4. For real isolation, run the child under `sandbox-exec` (macOS) or
   `bwrap`/namespaces (Linux) with the workspace as the only writable mount —
   the README already frames WASM as the isolation story; the shell path should
   not silently be the weakest link.

### E4-6 — Authenticate the tool-RPC path (fixes S4-1)

The RPC topic is a remote-execution API with no auth. Options, cheapest first:

- Require a shared secret in the request envelope (`{"token": …}`) sourced from
  the same non-ENV secret store, compared in constant time; reject and log
  otherwise. Add a per-request nonce/timestamp to prevent replay.
- Or disable the RPC listener unless `RUNES_TOOL_RPC=1`, leaving planner-driven
  execution as the only path.
- Independently: subscribe only to `runes/tools/<this-agent>/request` (addressed)
  instead of the `+` wildcard, and keep the broker on localhost with an ACL if
  a real broker is used.

Also add a regression test that asserts an unauthenticated request is refused —
the current suite has no test for the authorization *absence*.

### E4-7 — Feed the verifier real evidence

Stop deriving the verifier input from the 200-char `summarize` line. Keep a
per-step evidence buffer during `execute_mission_step` (raw outcome, truncated
once to a documented limit such as 4–8 KiB total, with explicit
`[truncated]` markers) and pass that to `verify_mission_step`. Distinguish
"evidence present but short" from "evidence missing" in the prompt so the
fail-closed verdict stays meaningful (B4-6).

### E4-8 — Route mission steps through the same planner path as build mode

`execute_mission_step` should call `use_tool_calling? ? @llm.call(step_prompt,
tools: tool_schemas) : @llm.call(step_prompt)` — or better, extract one
`plan_for(prompt)` helper used by both `handle_build_prompt` and the mission
executor so the two paths cannot drift again (B4-5).

### E4-9 — Make provider error handling shape-proof

At `llm_client.rb:382`, don't `dig` blindly:

```ruby
err_obj = parsed.is_a?(Hash) ? parsed['error'] : nil
msg = case err_obj
      when Hash  then err_obj['message'] || err_obj.to_json
      when String then err_obj
      else response.body
      end
```

Add unit tests for `{"error": "str"}`, `{"error": {...}}`, `{"error": [...]}`,
`{"message": "x"}`, and a non-JSON body — all five are one line of test each
and none currently exist (B4-2).

### E4-10 — Test-infrastructure hardening

- `popen_script` (`cli_tools_test.rb:32-52`): close the write ends, wait for
  EOF with a bounded read instead of `Timeout` + unconditional `close`, and
  `join` with a rescue for `IOError` so a slow process reports a useful failure
  rather than "stream closed in another thread" (B4-1).
- Add an `Minitest` helper for env isolation (`with_env('RUNES_X' => 'y') { … }`)
  and use it in the ~10 tests that currently assign directly to `ENV`.
- Point every test's `Settings` at a temp `root` so `rake test` stops appending
  to the developer's `log/journal.jsonl` and sharing `runes.db` (B4-13).
- Add a `rake test:deterministic` task that runs the suite with 2–3 fixed seeds
  to catch order dependence.

### E4-11 — Durable journal across processes

Rotate to a timestamped name (`journal-<iso8601>.jsonl`) instead of a fixed
`.1`, or take an exclusive `flock` around the size-check + rename + append so
concurrent dispatchers cannot clobber each other (B4-7). Keep the `.1` name as a
read-compatibility symlink if `bin/runes-replay` depends on it.

### E4-12 — Small correctness and observability wins

- `write_file`: treat `""` as valid content and distinguish "missing
  content key" from "empty"; reject only `nil` (B4-8).
- `RUNES_WASM`/`RUNES_WASM_TIMEOUT_S`: route through `Settings#env`, or state in
  the README that they must be real environment variables (B4-9).
- Prompt caps: slice on bytes (`prompt.byteslice(0, MAX_PROMPT_BYTES)`) after
  the byte check (B4-10).
- Broker: leave a `@qos2` packet-id set (bounded, with a TTL) so DUP PUBLISHes
  are not re-delivered; require CONNECT before PUBLISH/SUBSCRIBE; validate the
  Will topic against wildcards (B4-11).
- `LLMClient`: add `max_tokens` (a `RUNES_MAX_TOKENS` knob — currently the
  provider default silently governs cost and truncation behaviour), log
  `usage`/`finish_reason` per call into the journal, and retry
  `Errno::ECONNRESET`/`EPIPE`/`SocketError` once (today only timeouts and
  429/5xx retry).
- `.gitignore` covering `config/.env`, `runes.db*`, `log/`, `workspace/`,
  `tmp/`, `ruby.wasm`, `docs/epics/`, `docs/missions/` — and a pre-commit
  secret scan (`gitleaks`/`detect-secrets`) since a key has already been
  written into the tree once (S4-3).

### E4-13 — Documentation as a build artifact

Generate the test-count line (README/STATE) from the suite instead of typing
it, or drop the number and link to the runbook. Fix the `.env` description,
`rakes-replay`, and the two `RUNES_WASM*` entries (B4-12). A 3-line
`rake docs:check` that greps for stale numbers vs. a `test/.last-run` file
would have caught four of these.

### E4-14 — TUI input/output hardening

- Validate parsed JSON shape, not just parseability: `parsed.is_a?(Hash) ? parsed
  : {}` at `bin/runes:167` and `:187` (T4-1).
- Sanitize the **topic** as well as the payload before matching, or match with
  `topic.to_s.b` / `scrub` first (T4-2).
- Extend `CONTROL_CHARS` to `\x09`/`\x0a` and collapse whitespace on the status
  and generic-progress paths, or route every traffic line through one
  `display_line` helper that sanitizes + collapses + column-truncates (T4-5,
  T4-9).
- Sanitize pasted/piped input the same way as broker input before it reaches
  `@input` and the renderer (T4-6).
- Move the retry-backoff reset after a successful subscribe/consume, cap
  `@traffic` in `traffic_notice`, drain to `PASTE_END` (or flush the input
  queue) when the paste cap trips, connect the publisher off the input thread,
  and reorder `run_input`'s `ensure` so `stop` precedes the escape-sequence
  write (T4-3, T4-4, T4-7, T4-8, T4-10).

---

## Suggested priority order

| # | Item | Why first |
|---|---|---|
| 1 | **S4-1** authenticate/disable the tool-RPC path | remote execution, no credentials required |
| 2 | **S4-3** `.gitignore` + key handling | one `git init` from permanent credential exposure |
| 3 | **S4-2** `run_command` boundary | `rm -rf ..` reachable from a planner step |
| 4 | **B4-1 / B4-13 / E4-2 / E4-10** make the suite green and deterministic | every later change depends on a trustworthy signal |
| 5 | **B4-3 / E4-3** fix the claim protocol | correctness of the core safety property |
| 6 | **E4-1** DeepSeek provider | unblocks live validation the docs claim already works |
| 7 | **B4-2 / E4-9** error-path crash | cheap, and currently masks every HTTP failure |
| 8 | **B4-4 / B4-5 / B4-6 / E4-4 / E4-7 / E4-8** mission pipeline | the executor's three defects compound |
| 9 | **B4-7 / S4-4 / S4-5 / E4-11 / E4-12** durability & hardening | real but lower blast radius |
| 10 | **B4-12 / E4-13** docs | prevents the next reader from trusting false status |

**T4-1/T4-2 + E4-14** (TUI reader crashes and renderer escapes) are high
severity but behind S4-1: a hostile publisher on the broker can already do
anything the daemon can, so the TUI hardening matters most once broker access is
scoped (E4-6) — or immediately if the TUI is pointed at a shared broker.

---

## Appendix — reproductions

All scripts are scratch files under `tmp/` and can be deleted afterwards.

```
tmp/repro_dig.rb      B4-2  provider error-body TypeError (stubbed HTTP)
tmp/verify_flaws.rb   S4-2  run_command escapes the workspace (`rm -rf ../victim`)
                      B4-4  extract_json_object, C of the config check
                      S4-3/E4-1  DeepSeek key parsed but unregistered
tmp/verify2.rb        B4-4  unbalanced braces inside JSON strings
tmp/poc_rce.rb        S4-1  unauthenticated `run_command` + read_file over MQTT
tmp/poc_dup.rb        B4-3  two agents execute the same broadcast
```

Suite evidence (7 full runs on 2026-09-10: 5 green, 1 failure, 1 error):

```
bundle exec rake test                          # run 1: 1 failure (live test, TypeError)
bundle exec rake test TESTOPTS="--seed=5407"   # 1 error (pipe reader race) + 1 skip
bundle exec rake test TESTOPTS="--seed=14936"  # same cli_tools error
bundle exec rake test                          # x5: 202 runs, 532 assertions, 1 skip
```

TUI findings T4-1…T4-7 and T4-9 were reproduced by driving the real
`bin/runes` methods (no files modified); T4-1, T4-2, T4-4 and T4-5 were
re-verified against the source while writing this document.
