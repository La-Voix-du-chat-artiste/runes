# Runes 🌀

RUNES: "**RU**by har**NES**s" for agentic tool coordination — riding on a
pluggable messaging fabric, governed by a capability model, remembered by a
durable journal, and watched by an observatory.

LLM planners decompose intents into tool calls; trusted host tools execute
them inside a confined workspace; `ruby.wasm` sandboxes run untrusted tool
code. Interactive modes shape an idea into an **Epic**, refine it into a
**Mission** (an ordered todo list), then **build** it — one verified todo at
a time.

Runes is a **sandboxed, auditable agent-execution fabric for local-first
fleets**. The bet: in the agentic era, the harness — fabric, identity,
guard, journal, language — is the runtime, and the team that masters it
owns its infrastructure instead of renting a dashboard. The 8-page pitch
PDF is [`docs/WHY_RUNES_V2.pdf`](docs/WHY_RUNES_V2.pdf) (generated from the
markdown it describes, so the two cannot drift). The "why" (what we are
*not* competing on, the moat, honest risks) is
[`STRATEGY.md`](STRATEGY.md); the longer pitch is
[`docs/WHY_RUNES_V2.md`](docs/WHY_RUNES_V2.md).

> **Status (2026-11-11): 0.4.0 shipped — the fleet layer is real.**
> (1) **The transport-agnostic series** — the MQTT fabric is one adapter
> behind `Runes::Transport` (`inproc | mqtt311 | mqtt5`); the claim/lease
> protocol was *deleted* in favour of MQTT 5 shared subscriptions; agents
> speak A2A-over-MQTT discovery/tasks and MCP tools in both directions,
> with per-agent Ed25519 identity and a mosquitto ACL generator. The
> suite is **fully offline**. (2) **The fleet layer (0.4.0, shipped)** —
> `.fleet.rb` files declare a world + rules in a restricted, statically
> analyzable Ruby subset: fail-closed Prism-whitelist loading, rules that
> fire deterministically with ledger-backed ids, and policy/ACL/topology
> extracts golden-tested at L2 conformance — `runes-daemon --fleet
> world.fleet.rb` runs one: [`docs/FLEET_DSL.md`](docs/FLEET_DSL.md).
> (3) **WASI guests (roadmap)** — compiling agents to WebAssembly via
> Spinel's C output, as capability-sandboxed guests. The first mile of that
> road is already walked: the harness **kernel compiles under Spinel
> today** — a 1.8 MB native binary passes a 70-check self-check (guard,
> ledger, transport, libcrypto Ed25519/HMAC via FFI, `posix_spawn`
> containment, the workflow engine), see [The compiled
> kernel](#-the-compiled-kernel-spinel) below. (4) **The contracted LFM3
> team (Cycle 43)** — a benchmark harness where every model call goes
> through a manifest, an identity/capacity/decision envelope, a contract
> guard and a ledger, run over a frozen 24-case suite against the real
> LiquidAI MLX packs. Two pilots, both **NO-GO** (2026-11-04, and the
> 2026-11-11 re-run after the stamp-mode fix): the same-model control
> beats the team and the modality lift is negative — a published negative
> result, numbers in the decision records:
> [`bench/swarm/`](bench/swarm/README.md),
> [`docs/SMALL_MODEL_HARNESS_PRD.md`](docs/SMALL_MODEL_HARNESS_PRD.md).
> See *Where this goes next*
> below. `STATE.md` for the suite count,
> `DEVELOPMENT_LOG.md` for the history, `STRATEGY.md` for the positioning.

## 🧭 The thesis in four lines

- **The future of coding is not writing code — it is conducting it.** When
  the machine writes parts of the program at runtime, what compounds is
  everything around the generated code: fabric, identity, guard, journal,
  language.
- **A DSL is the right abstraction for a swarm** — and the *semantics* of
  the DSL, not the syntax, is the asset. The seven runes have a frozen
  semantic contract (below) that outlives any implementation.
- **A fleet is a world, not a call graph.** 0.4.0 adds the declarative
  layer: declare agents, channels, routes, facts; react with rules. The
  guard and the broker ACL are *derived* from the same file a human reads.
- **The alternative to a SaaS is not a smaller SaaS — it is a file.**

## 🏗️ Architecture

```
   TUI / CLI ──▶ runes/prompts ──▶ Dispatcher ──▶ LLM router (multi-provider)
                                        │
                                        ▼
                              mode: build | goal | plan | mission
                                        │
                        Planner / Chat ──▶ steps / todos / verdicts
                                        │
             ┌──────────────────────────┴──────────────────────────┐
             ▼                                                     ▼
      Guarded host tools                              WASM tool pool (opt-in)
      write_file read_file run_command                ruby.wasm via wasmtime
             │                                                     │
             └──────────────────────┬──────────────────────────────┘
                                    ▼
              Runes::Transport  (inproc | mqtt311 | mqtt5 | wasi_guest)
              MQTT 5 ── shared subscriptions + PUBLISH properties
                                    │
             ┌──────────────────────┼───────────────────────┐
             ▼                      ▼                       ▼
       runes/# fabric         $a2a/v1 discovery        MCP stdio
       prompts · progress     + tasks (Agent Cards)    bin/runes-mcp
       response · tasks                               (guarded builtin
       tools · journal                                + manifest tools)
```

## 📜 The contract: the semantics of the seven runes

Not the syntax — the *semantics*. Frozen, so the implementation can move
(interpreted Ruby today, Spinel-AOT tomorrow) without breaking user code.

| Axiom | Statement |
|---|---|
| 1. Declaration is not execution | `rune(:x)` declares; `rune!(:x)` executes; `rune?(:x)` asks |
| 2. Execution is memoized | a step runs once; a replay returns the recorded outcome |
| 3. The body declares its input | a step returns what it consumes — the data graph is explicit, readable by a human, an agent, and the observatory |
| 4. Each rune has a type of output | `out/err/status` · `value` · `response/session` · `iteration(i)` · opaque subroutine |
| 5. Control is by verdict | `skip!`, `next!`, `break!`, `fail!` — no hidden control flow |

Everything else — Roast compatibility, the plugin registry, journaling,
replay, the observatory timeline — follows from these five axioms.

## 🗺️ The fleet layer — world + rules (0.4.0, shipped)

Workflows say *how to compute a result*; fleets say *who exists, who may
touch what, and what happens when the world changes*. The Fleet DSL
(`docs/FLEET_DSL.md`) is a declarative layer in a **restricted, statically
analyzable Ruby subset** — the Inform 7 lesson (declared world, reactive
rules) with discipline instead of natural-language parsing:

```ruby
fleet "prospection" do
  transport :mqtt5

  agent :writer do
    model "glm-5.3-flash"
    tools fs_write: :allow          # default-deny, always
  end

  route :scraper, :writer, :reviewer

  on :contact_qualified do |e|
    next! unless e.score > 0.7
    task :writer, "Redige l'email pour %{name}"
  end

  on :guard_denied do |e|
    notify "Refus: #{e.agent} / #{e.tool}", level: :warn
  end
end
```

Three properties: **statically analyzable** (Prism AST whitelist, fail-closed
load — no subscriptions, no grants left behind on failure); **the guard sees
it** (policy + mosquitto ACL extracted at load time — closing the "guard does
not see runes" gap for the declarative layer); **AOT-ready** (the subset is
chosen to compile under Spinel with no rewrite).

Run one: `bin/runes-daemon --fleet examples/prospection.fleet.rb` — the
world loads fail-closed, rules fire with ledger-backed deterministic ids,
and the journal (boot fingerprint first) lands in `log/fleet-*-journal.jsonl`.
`bin/runes-acl --fleet examples/prospection.fleet.rb` renders the merged
mosquitto ACL, fleet roles becoming first-class broker users. The
step-by-step semantics and the L1/L2/L3 conformance levels:
[`docs/FLEET_DSL.md`](docs/FLEET_DSL.md).

v0.2 landed: **rule priorities** (`on :x, priority: 10 do … end` — higher
fires first, ties keep declaration order), **mutable cells**
(`cell :hits, initial: 0` + `set :hits, …` in rules, every set journaled as
a write-ahead `fact_set` entry before it is applied), and
**planner-driven worlds** — `/done` now also emits the world as a
`.fleet.rb` file from the goal session, validated fail-closed by the real
loader before it is written to `worlds/` (`RUNES_FLEET_EMIT=0` opts out).

## 🤖 The contracted LFM3 team (Cycle 43)

A small-model team where **no model call is anonymous**: every role is a
manifest in `config/agents/` (`agent_id`, `base_model`, `capacities`,
`forbidden_actions`), every call is wrapped in an **ICC envelope**
(IDENTITY / CAPACITIES / DECISION / BODY — for text roles the adapter
*stamps* identity/capacity from the manifest and the model returns only
DECISION + BODY), checked by a `ContractGuard` checkpoint, and receipted
in a `WorkLedger`. A deterministic Ruby `Conductor`
(`lib/runes/orchestration/`) routes by triage verdict — the model never
chooses its own identity, shape or next hop — and declines with a typed
reason when the task is out of scope.

The proof rig is a frozen **24-case benchmark** (`bench/swarm/`, six
families: text, vision, audio, audio-video, decision, out-of-scope) with
synthetic CC0 fixtures, independent mechanical checks, and a Markdown+JSON
report per run. Run it against the official MLX packs:

```bash
ruby bench/swarm/runner.rb --arm team-full --seeds 0 \
  --model LiquidAI/LFM3-1.7B-MLX-4bit --python tmp/venv-swarm/bin/python \
  --out bench/swarm/results/pilot.md --json bench/swarm/results/pilot.json
```

**Pilots 2026-11-04 and 2026-11-11 (24 cases × 1 seed, cold command mode,
real checkpoints): both NO-GO.** The first pilot (team-full 4/24, 44
contract violations, decline recall 0.80; the same-model-3x control passed
7/14) exposed two harness defects, both fixed and re-measured: stamp-mode
envelopes and the scope gate with declared capacities in triage. The re-run
(team-full 6/24, ECE 0.54 → 0.36, d1-only decline recall 0.00 → 1.00,
false-answer 1.00 → 0.00) still fails the gates — text lift is −14.3 pp
against the stronger solo baseline and the modality lift is negative. The
remaining gap is model capability (citations at the 320-token cap, audio
perception sufficiency), not harness. Decision records:
[`2026-11-04-pilot.md`](bench/swarm/results/2026-11-04-pilot.md) and
[`2026-11-11-rerun2-decision.md`](bench/swarm/results/2026-11-11-rerun2-decision.md);
design: [`docs/SMALL_MODEL_HARNESS_PRD.md`](docs/SMALL_MODEL_HARNESS_PRD.md)
+ [`docs/SMALL_MODEL_HARNESS_PLAN.md`](docs/SMALL_MODEL_HARNESS_PLAN.md);
how to run: [`bench/swarm/README.md`](bench/swarm/README.md).

## ✨ Features

- **Transport-agnostic fabric** — the dispatcher talks only to
  `Runes::Transport`: an **in-process hub** (tests, offline demos, embeds),
  an **MQTT 3.1.1** adapter (classic `mqtt` gem) and a hand-rolled **MQTT 5**
  adapter (shared subscriptions + PUBLISH properties).
  `RUNES_TRANSPORT=auto` probes 5 → 3.1.1 → inproc.
- **Embedded MQTT broker (dev convenience)** — QoS 0/1/2 with dedup, LWT,
  retained messages with count **and byte** budget, wildcards, packet caps;
  production points at mosquitto/EMQX.
- **Exactly-once work** — MQTT 5 shared subscriptions hand each prompt to one
  group member; `Runes::RequestLedger` dedupes execution by `request_id`
  across prompts, A2A tasks, delegations and tool RPCs. Prompts run on a
  fixed worker pool, never on the transport's receive thread.
- **A2A-over-MQTT** — retained Agent Cards on
  `$a2a/v1/discovery/<org>/<unit>/<agent>`; tasks answered via Response
  Topic / Correlation Data.
- **MCP, both directions** — `bin/runes-mcp` serves guarded tools over stdio;
  `Runes::MCP::Client` spawns external MCP servers through the provider seam.
- **Per-agent identity** — Ed25519 keypairs, canonical signed JSON envelopes,
  fail-closed trust store, `bin/runes-acl` for least-privilege broker ACLs.
- **Default-deny capability guard** — per tool *and* per action
  (`fs_write` / `fs_read` / `exec`) on the resolved path, enforced on both
  the planner path and direct RPC; every refusal is published on
  `runes/guard/denied` and counted by the observatory.
- **Function-calling planner** — OpenAI-style `tools` schemas + structured
  `tool_calls` (opt out via `RUNES_USE_TOOLS=0`).
- **WASM sandbox (opt-in, validated)** — real `ruby.wasm` boot with WASI,
  code via stdin, 5B fuel budget; deterministic mock backend by default.
- **The WASI transport guest (first real guest)** — until now guests were
  one-shot scripts; `Runes::Transport::WasiGuest`
  (`RUNES_TRANSPORT=wasi_guest`) keeps the fabric itself (subscriptions,
  retained messages, shared-group round-robin) in a **long-lived guest**,
  reached through the ordinary transport contract over a framed file
  bridge on the guest's WASI preopen. The same guest program runs under
  CRuby (suite-spawned, fully tested), ruby.wasm, and — the point — a
  Spinel-compiled fleet later: [`docs/wasi-transport-guest.md`](docs/wasi-transport-guest.md).
- **Durable journal** — every prompt lifecycle appended to
  `log/journal.jsonl` (rotated, `flock`-protected) and published on the bus;
  `bin/runes-replay` shows or replays it.
- **Roast-compatible workflows** — an unmodified Shopify Roast `.rb` file
  runs as-is; see [Runes](#-runes-roast-compatible-workflows).
- **Contracted small-model teams** — manifests + ICC envelopes (stamp mode
  for text roles) + a deterministic conductor + a 24-case benchmark over
  the LFM3 suite; two pilots, both NO-GO, published with numbers (above).

## 🚀 Quick Start

New here? [`docs/GETTING_STARTED.md`](docs/GETTING_STARTED.md) (also as
[PDF](docs/GETTING_STARTED.pdf)) is the 5-minute tour: what Runes can do,
setup, and the scripted-kanban demo to run first — no API key needed.

```bash
git clone https://github.com/La-Voix-du-chat-artiste/runes
cd runes
bundle install
cp config/.env.example config/.env
# edit config/.env — set DEEPSEEK (preferred: V4.1 Flash, model
# `deepseek-flash`, variation high) and/or SYNTHETIC / CEREBRAS_API_KEY.

# 1) offline smoke test (embedded broker, stub planner — no API key)
bundle exec ruby demo/smoke.rb

# 1b) the scripted kanban demo — the full prospect pipeline, offline, no key:
#     idea → goal.md → mission .mmd kanban → verified todos → CRM drafts → report
RUNES_DEMO_SCRIPTED=1 bundle exec ruby -Ilib scripts/demo_pipeline_run.rb

# 2) live end-to-end demos (real LLM)
bundle exec ruby demo/hello_world_live.rb     # build mode, hello world + minitest
bundle exec ruby demo/modes_live.rb           # /goal → epic → /plan → mission
bundle exec ruby demo/build_mission_live.rb   # /build: plan→execute→QA-verify

# 3) interactive use (multi-agent fleets: RUNES_TRANSPORT=mqtt5, mosquitto 2.x)
mosquitto -p 1883 &                          # or: bundle exec ruby demo/broker.rb 1883
RUNES_TRANSPORT=mqtt5 ./bin/runes-daemon &   # shared-subscription agent
./bin/runes                                  # the TUI ( Registry | Traffic | Input )
./bin/runes-client --agents                  # who is listening, and where they write
./bin/runes-client "prompt"                  # one-shot CLI prompt

# 4) interop + broker access control
./bin/runes-mcp                     # MCP server: guarded tools over stdio
./bin/runes-acl --agent runes-a     # print a fail-closed mosquitto acl_file

# 5) declarative workflows (Roast DSL)
./bin/runes-workflow execute examples/analyze_codebase.rb

# 6) discovery phase: brief + repo -> verified discovery.v1 card (anchors
#    resolved by Ruby, loop detector on) — needs a provider key for the
#    chat calls; the suite runs it offline (test/discovery_test.rb)
RUNES_DISCOVERY_BRIEF="Add a kanban board to the observatory" \
RUNES_DISCOVERY_REPO=$PWD RUNES_DISCOVERY_OUT=tmp/discovery \
  ./bin/runes-workflow execute examples/discover_codebase.rb
```

## 🏭 A real pipeline, as a workflow

`examples/prospect_pipeline.rb` (~460 lines) is the whole engine of a
CRM/product pipeline in one readable file: idea → `goal.md` → mission `.mmd`
kanban → every todo executed and verified → next action per contact → drafted
(never sent) outreach → weekly report. The same file is readable by a human,
an agent and the Rails app — the "we built the engine you can tweak in one
line" argument, in code.

Then read [`docs/DSL_POWER.md`](docs/DSL_POWER.md): the whole DSL on one
page, the pipeline scope by scope, and the sharp edges.

And `examples/discover_codebase.rb` — the pre-swarm **discovery phase**
([design](docs/runes-pre-swarm-discovery-phase-for-lfm3-1-7b.md)): brief +
repo → Ruby-built renderings (tree/imports/tests/churn/docs of one
`state_id`) → one typed `finding.v1` per fresh-context call → Ruby resolves
every `file:line` anchor mechanically → a verified `discovery.v1` card that
`/plan` consumes. Loop detector included. Runs offline in the suite:
`test/discovery_test.rb`.

## 🧩 Runes (Roast-compatible workflows)

Byte-for-byte Roast's README example:

```ruby
execute do
  cmd(:recent_changes) { "git diff --name-only HEAD~5..HEAD" }

  agent(:review) do
    files = cmd!(:recent_changes).lines
    "Review these for security, performance and maintainability:\n#{files.join("\n")}"
  end

  chat(:summary) do
    "Summarize this for non-technical stakeholders:\n\n#{agent!(:review).response}"
  end
end
```

A workflow is a plain `.rb` file `instance_eval`'d against the workflow
object; inside a step, `self` *is* the step's input context — which is why
`cmd!(:name)` is a method call, not a variable.

### The seven runes

| Rune | Runs | You read from it |
| --- | --- | --- |
| `cmd` | a process (argv or shell string) | `out`, `err`, `status`, `lines` |
| `ruby` | a block, its value is the output | `value`, `[]`, `call` |
| `chat` | one prompt against an LLM provider | `response`, `session` |
| `agent` | a coding agent CLI with the prompt on stdin | `response`, `session`, `stats` |
| `map` | a step body once per item (threaded with `parallel`) | `iteration(i)`, `first`, `last` |
| `repeat` | a step body until `break!` / `max_iterations` | `value`, `results` |
| `call` | a saved scope, as a subroutine | opaque — extract with `from(...)` |

### Each rune is a plugin

```ruby
class Runes::Plugins::Cmd < Runes::Rune
  plugin :cmd, description: "Run a process and capture its output"
end
```

A third party adds a verb by dropping in a class — no engine change — and
inherits journaling, replay and the observatory, because a rune is a plugin,
not a special case. Full contract and Roast matched-vs-deviations:
[`docs/WORKFLOWS.md`](docs/WORKFLOWS.md). Known gap, stated: the guard does
not yet see workflow runes (the fleet layer closes this for its declarative
subset by construction).

## 🎛️ Interactive modes (TUI)

Slash commands are parsed locally, never published as prompt text.

| Command | What it does |
|---|---|
| `/goal <text>` | Rubber-duck + PM session: reflects back, asks 2–4 direction questions per turn, never writes code. |
| `/done` | Renders the session into an **Epic** at `docs/epics/<ts>-<slug>.md`; invalid renders are rejected and the session stays open. |
| `/plan [text]` | Brief (or latest epic) → **Mission** at `docs/missions/<ts>-<slug>.md` + `.json` sidecar: 3–9 ordered todos with acceptance criteria. Invalid JSON → one re-ask → fail-loud. |
| `/build <mission>` | For each pending todo: plan → execute through guarded tools → strict QA verifier judges the acceptance criteria against recorded evidence. Stop on first failure; re-run resumes (done todos skipped). |
| `/agents`, `/help` | Fleet visibility / command reference. |

Non-TUI clients: `runes-client --mode goal|plan "…"`, `--agents`,
`--agent <id> "…"` (targeted task via `runes/agents/<id>/tasks`).

## ⚙️ Configuration

| Env var | Default | Purpose |
|---|---|---|
| `DEEPSEEK` / `DEEPSEEK_API_KEY` | — | DeepSeek API key (preferred; V4.1 Flash) |
| `SYNTHETIC` / `SYNTHETIC_API_KEY` | — | Synthetic API key (GLM models) |
| `CEREBRAS_API_KEY` / `CEREBRAS` | — | Cerebras API key (optional) |
| `RUNES_DEFAULT_PROVIDER` | auto | `deepseek` > `synthetic` > `cerebras` |
| `RUNES_DEFAULT_MODEL` | provider default | Model id or alias |
| `RUNES_DEFAULT_VARIATION` | `high` | `high`/`balanced`/`low` (`max`) |
| `RUNES_ROOT` | `<project>/` | Redirect DB/journal/docs/tools |
| `RUNES_WORKSPACE` | `<project>/workspace/` | Where tools may read/write/run |
| `RUNES_POLICY` | `config/policy.json` | System-wide capability policy |
| `RUNES_WASM` | `mock` | `real` enables the ruby.wasm backend |
| `RUNES_MQTT_HOST/PORT` | `127.0.0.1`/`1883` | Broker endpoint |
| `RUNES_TRANSPORT` | `auto` | `auto`/`inproc`/`mqtt311`/`mqtt5`/`wasi_guest` (the fabric in a WASI guest) |
| `RUNES_REQUIRE_SHARED_SUBSCRIPTIONS` | unset | `1` makes missing `$share` fatal |
| `RUNES_REQUIRE_SIGNATURES` | unset (**off**) | `1` requires signed envelopes |
| `RUNES_TRUST_DIR` | `<root>/config/trust` | Trusted peer public keys |
| `RUNES_TOOL_RPC` | unset (**off**) | `1` enables tool RPC topic |
| `RUNES_RPC_SECRET` | — | Shared secret for tool RPC (constant-time) |
| `RUNES_CMD_ALLOWLIST` | unset | Permitted command binaries (exclude interpreters!) |
| `RUNES_MAX_CONCURRENT` | `4` | Prompt worker pool size |
| `RUNES_REDACT_PROMPTS` | unset | `1` redacts prompts in the journal |
| `RUNES_TELEMETRY` | unset | Workflow run telemetry → observatory + `guard/denied` |

See `config/.env.example` for the complete list
(`RUNES_MAX_STEPS`, `RUNES_LLM_TIMEOUT_S`, `RUNES_WASM_TIMEOUT_S`, …).

## 📡 MQTT Topic Map

```
runes/agents/<id>/card                  retained — Agent Card (TUI/observatory)
runes/agents/<id>/status                retained — online|offline (LWT)
runes/agents/<id>/tasks                 addressed task envelope
runes/prompts                           broadcast prompt (JSON envelope)
$share/<group>/runes/prompts            shared-subscription form agents consume
runes/prompts/<req>/progress            event stream (JSON per event)
runes/prompts/<req>/response            correlated reply
runes/_log/prompts                      journal feed (+ /latest retained)
runes/tools/<t>/request|response|error  direct tool RPC (opt-in, secret-gated)
runes/guard/denied                      capability refusal {tool, action, resource, agent}
$a2a/v1/discovery/<org>/<unit>/<agent>  retained A2A Agent Card
$a2a/v1/tasks/<org>/<unit>/<agent>      A2A task (Response Topic / Correlation Data)
```

Payloads are JSON, deliberately: the bus is an audit surface, and `jq`,
`mosquitto_sub`, the journal and the observatory all read it without a
custom parser. MQTT wildcards never match `$`-topics — subscribe to
`$a2a/#` separately.

## 🔒 Security model

- **Workspace confinement** — `safe_path` rejects absolute paths, `..` and
  symlink escapes.
- **Command containment** — path tokens rejected before execution, plus
  metacharacter/destructive-verb filters, timeout with process-group kill,
  output cap, optional allowlist.
- **Guard on both paths** — planner-driven tools and direct RPCs both pass
  the capability guard, consulted on the *resolved* path.
- **Signed envelopes (opt-in)** — Ed25519 over canonical JSON, verified
  before the planner ever sees a message.
- **Refusals are events** — every `guard.denied` is published, rate-capped,
  and counted; refusals are the security-relevant half of what a fleet does.
- **Broker ACLs** — `bin/runes-acl` renders a fail-closed per-agent
  mosquitto `acl_file`; the embedded broker is dev-grade (localhost only).

## 🧪 Testing & demos

```bash
bundle exec rake test          # see STATE.md for the current run count
```

The suite is **hermetic and offline**: provider HTTP is exercised through an
injected **dup transport** (a real `Net::HTTPResponse` with a canned body),
broker tests spawn their own in-process broker on a free port — **no API
key, no network, no broker required**. Offline demos (no key):
`demo/smoke.rb` and the **scripted kanban pipeline**
(`RUNES_DEMO_SCRIPTED=1 bundle exec ruby -Ilib scripts/demo_pipeline_run.rb`
— runs `examples/prospect_pipeline.rb` end to end and prints the mission
`.mmd`; see [Getting started](docs/GETTING_STARTED.md)). Live demos (need a
real key): `demo/hello_world_live.rb`, `demo/modes_live.rb`,
`demo/build_mission_live.rb`, `demo/tool_calls_live.rb`, `demo/broker.rb`.

## 🛠 The compiled kernel (Spinel)

The CPU-bound, security-relevant core — topic matching, JSON, the guard,
command policy, the dedupe ledger, kanban, the in-process transport, the
crypto stack (Ed25519/HMAC via libcrypto FFI), `posix_spawn` process
containment, and the workflow engine (`cmd`/`ruby`/`call`/`map`/`repeat`)
— compiles with [Spinel](https://github.com/matz/spinel) (Matz's Ruby AOT
compiler) to a standalone native binary with **no CRuby and no sockets
required**. Verified 2026-10-01: `build/runes-kernel` (1.8 MB) passes the
kernel's 70-check self-check natively; the harness suite is unchanged
green. The seam discipline that made it possible: kernel code never touches
`eval`, dynamic `define_method`, or stdlib json/openssl/digest — a CI
linter enforces it (`test/spinel_subset_test.rb`), and the same self-check
runs under CRuby (Fiddle-bound parity) when no compiler is present.

```bash
SPINEL=/path/to/spinel ruby scripts/spinel_build.rb   # compile + native self-check
```

Full analysis, tier map (A: pure kernel · B: FFI backends · C: sockets/wasm,
deliberately deferred) and the compiler findings from the first native
build: [`docs/spinel-compatibility.md`](docs/spinel-compatibility.md),
plan and specs in [`docs/spinel/`](docs/spinel/PRD.md).

## 🔭 Runes Observatory (Rails 8.1)

A read-only companion app (`runes_observer/`) that watches the fabric:
fleet (running / stale / LWT-ended agents), workflow runs as timelines,
fleet topology (delegation edges: width = volume, colour = failure rate),
trace waterfalls (the *gaps* between packets), a live packet feed with raw
JSON, per-agent interactions grouped by `request_id`, a Mermaid kanban
fleet board at `/board` (`GET /board.mmd` hands the same text to an agent —
a board a program cannot read is a screenshot), **alerts** at `/alerts`
(deduped, counted, ackable — impersonation and signature-failure detectors
run in ingest, with a nav badge), and the **plugin catalog** at `/plugins`
(the seven runes rendered straight from the registry). Ingest goes through
`Runes::Transport`, so `inproc` mode needs no broker at all.

```bash
cd runes_observer && bin/rails db:prepare
mosquitto -p 1883 &  bin/runes-ingest  bin/rails server -p 3100
```

## 🧾 Receipts

Measured, not remembered — `ruby scripts/receipts.rb` prints all of them.

| | |
| --- | --- |
| `lib/` | **29 625 lines** across 131 files |
| `test/` | **19 639 lines** across 82 files |
| Suite | **1 125 runs, 6 677 assertions, 0 failures, 3 skips** — no keys, no network |
| Executables | **8**: TUI, daemon, client, MCP, replay, ACL, workflow, kanban |
| The seven runes | `agent` 728, `chat` 503, `repeat` 203, `cmd` 207, `map` 183, `ruby` 78, `call` 68 |
| MQTT 5 adapter | **1 148 lines**, hand-rolled, live-verified against mosquitto 2.1.2 — and it *reconnects* |
| Security surfaces | **1 770 lines** — guard, envelopes, identities, trust store, telemetry, RPC auth |
| Request ledger | **198 lines** — the execution half of exactly-once |
| Compiled kernel | **1.8 MB native binary, 70-check self-check green under Spinel** |
| Live proof | **200 messages, one shared group, 100/100 split, no dupes, no losses** |

## ⚠️ What we're honest about

- Distribution is exactly-once; execution is deduped **in-process**. A
  request with no `request_id` has no identity to dedupe on; a durable ledger
  is the next step.
- **Token scanning is not a sandbox.** `run_command` is path-confined; real
  untrusted-code isolation = WASM. The WASI guest roadmap (below) pushes this
  from guard-enforced to impossible-by-construction.
- Workflow runes ask permission only when asked to
  (`RUNES_WORKFLOW_POLICY`); its patterns match command text literally — it
  wants a narrow allowlist.
- A2A peer cards are unauthenticated (discovery-only). Message signing
  covers envelopes, not every progress event.
- `parallel` is threads: no cooperative cancellation of a running iteration.
- MQTT 3.1.1 is compatibility-only (no shared groups, no properties) and
  refuses loudly. The observatory has no auth — fine on localhost.
- One-shot tool feedback: a single build plan does not loop
  plan→execute→feed-back; missions compensate with verify-and-resume.
- Symlink TOCTOU in `safe_path`; TUI renders broker-supplied text (control
  chars stripped, but a hostile publisher can spoof panel text).
- The LFM3 team benchmark is a **published negative result**: two pilots,
  both NO-GO, with the decision records committed under
  `bench/swarm/results/` — we do not shop for a GO.

## 🧭 Where this goes next

Ordered, and each item is either specified, spiked or scoped — not vapour:

1. **The fleet layer's next mile (0.4.x)** — hardening landed: declared
   payload schemas validated fail-closed (§4.3), shared-group subscriptions
   so N runners split events instead of double-firing, presence *transitions*
   (retained replays no longer re-notify), and the fleet runtime's own
   broker identity (`fleet-<name>`, rendered by `bin/runes-acl --fleet` with
   exactly what the loaded rules publish). Still open: observatory
   `/topology` consuming fleet extracts, chat-driven world changes through
   the planner (the loader stays the only path in), and the spec's v0.2
   items (mutable cells, nested fleets, rule priorities): [`docs/FLEET_DSL.md`](docs/FLEET_DSL.md).
2. **WASI guests (spikes)** — Spinel emits C for a Ruby agent; compile that
   C to `wasm32-wasi` instead of a native `.exe`: **one signed artifact,
   sandboxed everywhere.** The host daemon embeds wasmtime and grants
   capabilities as imports — `runes:transport` (no sockets in the guest at
   all), `runes:sign` (private keys never enter guest memory),
   `runes:complete` (provider keys stay host-side) — and preopens exactly
   the workspace directory. WASI's capability model *is* Runes' security
   model, at the OS level. The first real guest landed instead of S1–S3's
   host imports: the **transport guest** (above) — the same effect through
   the preopen bridge the runtime already grants, proven on ruby.wasm
   today and reusable by the compiled fleet runtime. Remaining spikes:
   **S1** Spinel-C → wasi-sdk hello world; **S2** a *compiled* guest
   publishing a signed heartbeat through the same bridge; **S3** pooled
   alongside `ruby.wasm` (interpreted guest for untrusted *tools*,
   compiled guest for *agents*). The gate before any of it — the
   real-wasm round trip — is now green (`ENHANCEMENT.md` §1,
   `docs/wasi-transport-guest.md`).
3. **A plugin catalogue** (`/plugins`) generated from
   `Runes::Plugin.names` — "a rune is a plugin" as a page.
4. **Alerts** — impersonation and refusals get a row an operator can
   acknowledge, not just a panel.
5. **The plan chain on one page** — prompt → plan → tool calls → evidence →
   verifier verdict; then **runs diffed and replayed** ("re-run just the
   step that failed").
6. **An observatory that is an agent** — its own A2A card and MCP server, so
   any agent can ask *"what happened on the bus?"* mid-task.
7. **The Spinel conformance gate** — both halves run today: kernel files
   are lint-gated and the kernel compiles green (see *The compiled
   kernel* above), and the L3 fleet gate compiles + runs every
   `examples/*.fleet.rb` whole-program under Spinel (skip-on-refusal
   while the compiler matures, wrong-builds still fail). Extending the
   gate's vocabulary is the ongoing work, non-blocking.
8. **The LFM3 team's answer quality at the token cap (Cycle 43 follow-up)**
   — the 2026-11-04 pilot was NO-GO and the 2026-11-11 re-run (after the
   stamp-mode envelope fix, the scope gate and declared capacities in
   triage — all landed) is still NO-GO: team-full 6/24, text lift −14.3 pp
   vs the solo baseline, modality lift negative. The dominant remaining
   failure is `repair_exhausted`: the 1.7B's answers at the 320-token cap
   miss citations/patterns and one repair round does not clear the
   verifier. Next: raise per-role `max_output_tokens` for
   answerer/finalizer or tighten the checks to what a 1.7B reliably emits,
   plus a real out-of-sample calibration set for the 0.30
   perception-sufficiency threshold (audio scores 0.10–0.25). Decision
   records:
   [`2026-11-04-pilot.md`](bench/swarm/results/2026-11-04-pilot.md),
   [`2026-11-11-rerun2-decision.md`](bench/swarm/results/2026-11-11-rerun2-decision.md).
9. **The discovery phase's three-arm benchmark** — full discovery vs
   repo-map-only control vs one external call, with **mission acceptance in
   `/build`** as the downstream metric (the exploration-modality lift the
   pilots could not produce). Prototype shipped:
   `examples/discover_codebase.rb` + `Runes::Discovery`; the d1
   sufficiency judge and ideate A‖B fan-out still belong to the contracted
   layer. Design:
   [`docs/runes-pre-swarm-discovery-phase-for-lfm3-1-7b.md`](docs/runes-pre-swarm-discovery-phase-for-lfm3-1-7b.md).

## 📦 Project Layout

```
bin/runes            interactive TUI (modes, slash commands)
bin/runes-daemon     headless agent
bin/runes-client     one-shot CLI (–agents / –agent / –mode)
bin/runes-replay     journal viewer (+ --replay)
bin/runes-mcp        MCP server: harness tools over stdio
bin/runes-acl        fail-closed mosquitto acl_file generator
bin/runes-workflow   Roast-compatible workflow runner (execute FILE [steps])
bin/runes-kanban     validate .mmd kanban files (one file or --tree DIR)
lib/runes/plugin.rb  plugin registry (every rune is a kind: :rune plugin)
lib/runes/workflow/  workflow engine: DSL, config, execution manager, runes
lib/runes/plugins/   the seven runes: cmd, ruby, chat, agent, map, repeat, call
lib/runes/transport/ in-process hub, MQTT 3.1.1, hand-rolled MQTT 5
lib/runes/a2a/       A2A Agent Card + task shapes
lib/runes/mcp/       MCP protocol, stdio server, subprocess client, provider
lib/runes/security/  Ed25519 identity, signed envelopes, trust store
lib/runes/core/      dispatcher, llm_client (router), plan_parser, settings
lib/runes/mqtt/      embedded broker (dev convenience)
lib/runes/wasm/      VM pool (real ruby.wasm + mock)
lib/runes/capabilities/  guard + guard telemetry
lib/runes/swarm/     contracted-team manifests: identity, capacity, envelope,
                     contract guard, checkpoint, registry, model families
lib/runes/orchestration/  conductor (shape router + loop), team plan, guards,
                     legacy cumulative loop, work ledger receipts
lib/runes/llm/       model seams: LFM3/d1/media adapters, role profiles,
                     command + OpenAI-compatible transports
bench/swarm/         the 24-case contracted-team benchmark (runner, cases,
                     fixtures, report, results, README)
config/              .env, .env.example, policy.json
config/agents/       the swarm role manifests (agent_id, capacities, models)
docs/epics|missions/ artifacts of /goal, /plan, /build
tools/               tool manifests (card.json + capabilities.json [+ run.rb])
examples/            runnable sample workflows (Roast-compatible):
                     prospect_pipeline.rb (CRM kanban), discover_codebase.rb
                     (pre-swarm discovery card), analyze_codebase.rb
spin/                the Spinel kernel entry (compile to a native binary)
scripts/spinel_build.rb  compile + native self-check (SPINEL=/path/to/spinel)
scripts/demo_pipeline_run.rb  run the prospect pipeline demo (scripted: RUNES_DEMO_SCRIPTED=1)
scripts/md_to_pdf.rb     render a docs/*.md to its PDF (ruby scripts/md_to_pdf.rb IN OUT)
docs/spinel/         kernel PRD + tier specs (A pure · B FFI · C deferred)
demo/                smoke + live end-to-end demos
runes_observer/      Rails 8.1 MQTT observatory
STATE.md             full system snapshot (start here next session)
DEVELOPMENT_LOG.md   architecture decisions + phase-by-phase history
STRATEGY.md          positioning, moat and honest risks
docs/WHY_RUNES_V2.md  the longer pitch — why this is fun and why it matters
docs/spinel-compatibility.md  what compiles under Spinel, and the verified proof
docs/FLEET_DSL.md    the fleet layer spec (world + rules)
docs/OBSERVATORY_ROADMAP.md  what to build next in the observatory
docs/SMALL_MODEL_HARNESS_PRD.md   the LFM3 team PRD (Cycle 43) + pilot results
docs/SMALL_MODEL_HARNESS_PLAN.md  the coding plan (phases 0–8)
docs/LFM3_TEAM_DISCOVERY.md       the design source of truth
docs/GETTING_STARTED.md|.pdf      the newcomer's guide (setup + scripted kanban demo)
docs/runes-pre-swarm-discovery-phase-for-lfm3-1-7b.md  the discovery-phase design
```

## 📜 License

MIT.
