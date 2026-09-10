# Runes — System Snapshot (0.3.0)

> **Read this first when resuming.** 0.3.0 is the transport-agnostic series:
> the claim/lease consensus was deleted in favour of MQTT 5 shared
> subscriptions, the fabric became a pluggable `Runes::Transport`, agent
> discovery speaks A2A-over-MQTT, tools can be served/consumed over MCP,
> and envelopes can be signed with per-agent Ed25519 identities. Phase 17
> added a second front door: a **Roast-compatible workflow DSL** whose
> seven verbs (`cmd`, `ruby`, `chat`, `agent`, `map`, `repeat`, `call`)
> are registered as `kind: :rune` plugins, so a Roast `.rb` file runs
> unmodified. The user-facing story is `README.md`; the strategy is
> `STRATEGY.md`; the workflow contract is `docs/WORKFLOWS.md`; the history
> is `DEVELOPMENT_LOG.md` (Phases 16–17).

## Hands off to the next session

Where the current goal stands (it stays **active**):

- **Done:** round-5 audit implemented (Phase 18); audit leftovers — mqtt311
  reconnect, envelope freshness + forgery test, W5-6..W5-9, retention backstop
  (Phase 19); the observatory became a console — workflow telemetry + runs
  timeline (Phase 20), topology + interaction waterfall + traffic dashboard
  (Phase 21), and the publisher/observer topic contract (Phase 22).
- **Next, in order:** `O0.1` observatory ingest through `Runes::Transport`
  (MQTT 5 properties visible, the `mqtt` gem dropped, a broker-free `inproc`
  mode) and `E5-6` guard-aware runes (opt-in policy for `bin/runes-workflow`).
- **Known open items:** at-least-once *execution* (handlers are not idempotent;
  a bounded request ledger is the fix), envelope replay is closed but **A2A peer
  cards are still unauthenticated**, token scanning is not a sandbox, the
  observatory has no auth, and one-shot tool feedback. All are in the "What
  we're honest about" list in `docs/WHY_RUNES.md` and in `doc5.md`.
- **Regenerate the pitch PDF:** `ruby tmp/md_to_pdf.rb docs/WHY_RUNES.md
  docs/WHY_RUNES.pdf` (plain `ruby`, not `bundle exec`: prawn is a system gem).
- Working tree is a git repo with one commit per batch; `git log --oneline`.

## Test status

```
bundle exec rake test                 # parent harness: 555 runs / 2551 assertions / 0 failures
cd runes_observer && bin/rails test   # observatory: 124 runs / 629 assertions / 0 failures
bundle exec ruby tmp/verify_mqtt5_live.rb   # live mosquitto 2.1.2: ALL CHECKS PASSED
```

Live MQTT 5 proof (re-run 2026-09-10, mosquitto 2.1.2 on 1883): two clients
in one shared group received 25 messages **exactly once** (13/12 split, no
dupes, no losses), Response Topic/Correlation Data/User Property round-tripped,
a retained message reached a late subscriber, and keepalive held an idle
session open.

Current counts (2026-09-10, after Phase 22):
parent **527 runs / 2419 assertions / 0 failures / 0 errors / 0 skips**,
observatory **89 / 454 / 0** (the observatory suite was also re-run against a
database built from `db/schema.rb` alone, i.e. what a clean clone gets).
`lib/runes/core/dispatcher.rb` 1968 → 1545 → **1562** lines (the command
policy moved out), with `lib/runes/agent/{fabric,journal,session_store}.rb`
(403/93/77) holding the transport-facing, journal and session concerns.

The suite is now **actually** hermetic: no live provider calls (HTTP is faked
with a dup transport; the workflow runes are faked at their `command_runner` /
`provider_factory` / `backend` seams), every provider key and
`RUNES_LLM_ADAPTER` stripped from the environment, and broker-using tests start
their own broker on a free port — nothing dials 127.0.0.1:1883, which was
false before Phase 18 (`doc5.md` D5-1).

## Workflows (the Roast-compatible front door)

`lib/runes/workflow.rb` is the entry point; `lib/runes/rune.rb` defines
`Runes::Rune` (aliased `Runes::Cog`), and the seven verbs live in
`lib/runes/plugins/` as `kind: :rune` plugins — `cmd` (199 lines), `ruby`
(86), `chat` (503), `agent` (719), `map` (183), `repeat` (202), `call`
(68). Since Phase 18 a String command is `Shellwords.split` rather than
handed to `/bin/sh` (`shell: true` is the explicit opt-in), `cmd`/`agent`
take a `timeout`, and `repeat` is bounded. The engine is `lib/runes/workflow/` (workflow, cog, cog_input_context,
config_manager, execution_manager, task, system_rune, workflow_params,
util, errors) plus `lib/runes/command_runner.rb` (argv, no shell of its
own, `pgroup`, timeout, optional line handlers).

Entry: `bin/runes-workflow execute FILE [targets...] [-- key=value flag]`
(`--quiet` silences the final-output print; a failing rune exits 1).

Proof of compatibility: `test/roast_compatibility_test.rb` reads
`examples/analyze_codebase.rb` — the **Roast README example, byte for
byte** — and runs it with the cmd runner, the agent provider and the chat
backend faked, asserting the cross-step wiring (`cmd!(:x).lines` inside
the agent block, `agent!(:review).response` inside the chat prompt) and
that no network is touched. `test/workflow_cli_test.rb` exercises the
binstub out of process (exit codes, stdout vs stderr, argument splitting).

Honest gap: the runes do **not** consult the capability guard or
`RUNES_CMD_ALLOWLIST` — those live on the dispatcher/MCP tool path — so a
workflow can run commands the tool path would refuse, and a single-string
`cmd` is shell-interpreted exactly as Roast does. See
`docs/WORKFLOWS.md` § "Not yet done: the guard does not see runes".

## The 0.3 architecture in one diagram

```
  TUI / CLI ─┐
             ├─▶ Runes::Transport ──┬─ inproc   (tests, embeds, offline demos; shared groups natively)
  Dispatcher ┘   (publish/subscribe ├─ mqtt311  (compatibility; NO shared groups → solo consumer or fail)
                  /group/reply)      └─ mqtt5    (hand-rolled: $share groups, PUBLISH properties, CONNACK probing)
                        │
      ┌─────────────────┼──────────────────┬───────────────────┐
      ▼                 ▼                  ▼                   ▼
  Worker pool      A2A discovery        MCP (stdio)       Security
  planner →        $a2a/v1/discovery    server+client     Ed25519 identity,
  guard → tools →  $a2a/v1/tasks        bin/runes-mcp     signed envelopes,
  WASM sandbox     (legacy runes/…      (guarded tools)   bin/runes-acl
      │             cards still sent)
      ▼
  journal.jsonl + observatory (Rails 8.1, runes_observer/)
```

## Key interfaces

### Transports (`lib/runes/transport/`)
- `Base` — the contract: `connect/disconnect/connected?`, `publish(topic, payload, qos:, retain:, properties:)`,
  `subscribe(filter, qos:, group:, &block)`, `supports_groups?`, `supports_properties?`.
  A `group` subscription is a **shared** subscription: exactly one member receives each message.
- `InProcess` — process-local hub (reference implementation; retained + groups).
- `MQTT311` — the classic `mqtt` gem; `subscribe(group:)` raises `Unsupported`.
- `MQTT5` — MQTT 5 codec + client: `$share/<group>/<filter>`, Response Topic (0x08),
  Correlation Data (0x09), User Property (0x26), CONNACK shared-subscription probing.
- `Transport.build(kind:, settings:)`, `Transport.auto(settings:)`.

### Dispatcher (`lib/runes/core/dispatcher.rb` + `lib/runes/agent/`)
- `Dispatcher.new(broker_config=nil, wasm_path=nil, ui=nil, settings:, agent_id:, tool_registry:, transport:)`
- `start` — connect, subscribe, announce, park (handlers run on transport threads; workers do the work)
- Work: `subscribe(PROMPT_TOPIC, group: prompt_group)` → `handle_incoming_broadcast(message)`;
  on 3.1.1 it either fails (`RUNES_REQUIRE_SHARED_SUBSCRIPTIONS=1`) or warns and runs solo
- `handle_prompt(publisher, env, reply_topic:)` routes build/goal/plan/mission; `handle_payload(payload)` is the test/embed shortcut
- `Runes::Agent::Fabric` — subscriptions, A2A announce/discovery/tasks, delegation, signed-envelope enforcement
- `Runes::Agent::Journal` — `log/journal.jsonl`, timestamped rotation under a cross-process flock
- `Runes::Agent::SessionStore` — goal sessions (LRU cap, TTL, trim)
- Mission executor: `execute_mission_step` (plan → guarded tools → bounded evidence) → `verify_mission_step` (fail-closed)

### A2A (`lib/runes/a2a.rb`, `a2a/card.rb`, `a2a/task.rb`)
- `A2A.discovery_topic(org:, unit:, agent_id:)` → `$a2a/v1/discovery/<org>/<unit>/<agent_id>` (retained card)
- `A2A.task_topic(...)`, `A2A.status_properties('online'|'offline'|'working')`
- `Card.build` (A2A fields + `x-runes`), `Task.request/parse/status/to_envelope`

### MCP (`lib/runes/mcp/`)
- `MCP::Server` (stdio: initialize, tools/list, tools/call, ping), `MCP::Client` (spawns a server,
  JSON-RPC by id, stderr drain), `MCP::ToolProvider` (the seam), `bin/runes-mcp` (guarded builtin+manifest tools)

### Security (`lib/runes/security/`)
- `Identity.load_or_create(agent_id:, dir:, key_env:)` — Ed25519, 0600, `#fingerprint`, `#sign/#verify`
- `Envelope.sign(payload, identity)` / `Envelope.verify!(signed, trust_store)` — canonical JSON, fail-closed
- `TrustStore.load_dir(dir)` — empty store trusts nothing
- `Credentials.for_transport(settings)` — redacted broker credentials/token
- `bin/runes-acl` — generates a per-agent mosquitto ACL with no catch-all allow

## Environment variables (new or changed in 0.3)

| Var | Default | Purpose |
|---|---|---|
| `RUNES_TRANSPORT` | `auto`→mqtt311 | `inproc` / `mqtt311` / `mqtt5` / `auto` (probing) |
| `RUNES_PROMPT_GROUP` | `runes-prompts` | shared-subscription group for `runes/prompts` |
| `RUNES_REQUIRE_SHARED_SUBSCRIPTIONS` | unset | `1` = refuse to start when the transport cannot do groups |
| `RUNES_A2A` / `RUNES_A2A_ORG` / `RUNES_A2A_UNIT` | on / `runes` / hostname | A2A discovery + tasks |
| `RUNES_REQUIRE_SIGNATURES` | unset | `1` = verify inbound envelopes, sign outbound delegation |
| `RUNES_TRUST_DIR` | `<root>/config/trust` | peer public keys (`<agent-id>.pem`) |
| `RUNES_LLM_ADAPTER` | `builtin` | `ruby_llm` selects the community adapter (if installed) |

Removed with the claim protocol: `RUNES_CLAIM_WINDOW_S`, `RUNES_STARTED_GRACE_S`,
`RUNES_EXEC_TTL_S`. Everything else (tool caps, WASM, mission, MQTT host/port,
DeepSeek/Synthetic/Cerebras keys, provider preference) is unchanged — see the
README table.

## Project layout additions

```
lib/runes/transport/   Base + inproc/mqtt311/mqtt5 adapters + topic filter
lib/runes/a2a/         A2A card + task shapes (over-MQTT profile)
lib/runes/mcp/         MCP server, client, tool provider
lib/runes/security/    identity, envelope, trust store, credentials
lib/runes/agent/       Fabric, Journal, SessionStore (dispatcher mixins)
lib/runes/plugin.rb    plugin registry; every rune is a `kind: :rune` plugin
lib/runes/rune.rb      Runes::Rune (== Runes::Cog): base class for a step
lib/runes/workflow/    engine: cog, cog_input_context, config_manager,
                       execution manager, task/task group, params
lib/runes/plugins/     the seven runes: cmd, ruby, chat, agent, map, repeat, call
bin/runes-mcp          MCP stdio server for the harness tools
bin/runes-acl          mosquitto ACL generator
bin/runes-workflow     workflow runner (`execute FILE [steps...]`)
examples/              runnable Roast-compatible sample workflows
runes.gemspec, lib/runes.rb, lib/runes/llm*   packaging + adapter seam
STRATEGY.md, GEM_PACKAGING.md, docs/SECURITY.md, docs/WORKFLOWS.md
runes_observer/        Rails 8.1 observatory (fleet + packet UI, A2A aware)
```

## Known gaps / next steps

1. **Workflow runes bypass the guard** (Phase 17, narrowed in Phase 18):
   `cmd`/`agent` still do not consult the capability guard, so a workflow
   remains a way around it rather than through it. The *injection* half is
   closed — a String command is `Shellwords.split` into argv, a one-element
   argv never reaches `/bin/sh`, and a metacharacter token raises
   `CommandRunner::ShellSyntaxError` unless `shell: true` is explicit
   (`doc5.md` W5-1). What remains is making the runes guard-aware behind an
   opt-in policy for `bin/runes-workflow`; default-on would break unmodified
   Roast files. See `docs/WORKFLOWS.md`.
2. **Tool-result feedback** for single build plans is still one-shot; the
   tool-mode prompt states the plan is one turn (DeepSeek plans
   iteratively). A bounded plan→execute→feed-back loop is the next real
   feature; missions already compensate with verify/resume.
2. **MQTT 3.1.1 is compatibility-only**: no shared groups (solo consumer or
   `RUNES_REQUIRE_SHARED_SUBSCRIPTIONS=1` fails), and no PUBLISH properties,
   so A2A presence/decorrelation degrade to the legacy topic conventions.
3. **Signing covers envelopes, not every progress event**; replay
   protection (nonce/timestamp) is designed in `docs/SECURITY.md` §8 but
   not implemented.
4. **Broker auth/ACLs** are now *generatable* (`bin/runes-acl`) but the
   embedded broker remains dev-grade and the shipped demos still run
   unauthenticated on localhost.
5. **MCP client does not service server-initiated requests** (sampling,
   roots); stdio only.
6. **The observatory has no auth** and stores everything in SQLite; the
   live feed is poll-based.
7. **Symlink TOCTOU** on `write_file` (openat-style confinement would
   close it).

## Runbook

```bash
bundle exec rake test                        # no provider calls; needs a broker on 1883 (doc5.md D5-1)
bundle exec ruby demo/smoke.rb               # offline end-to-end (in-process)
bundle exec ruby tmp/verify_mqtt5_live.rb    # live shared-subscription proof (mosquitto)
RUNES_TRANSPORT=mqtt5 bundle exec ruby demo/hello_world_live.rb   # live build on DeepSeek

mosquitto -p 1883 &
RUNES_TRANSPORT=mqtt5 bundle exec ./bin/runes-daemon &
bundle exec ./bin/runes                      # TUI
bundle exec ./bin/runes-client --agents
bin/runes-mcp                                # expose the tools to any MCP client
bin/runes-acl --agent runes-a --a2a --out /tmp/runes.acl
cd runes_observer && bin/runes-ingest & bin/rails server -p 3100
```

House rules: scratch files in `./tmp` (never `/tmp`); never touch `~/Boxes`;
verify suspicions empirically before claiming a bug; never add a test that
calls a real provider (inject a dup transport instead).
