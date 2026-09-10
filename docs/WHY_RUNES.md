# Why Runes — the pitch, for engineers

*A Ruby agent harness with a fabric, an identity, a memory, and a face.
Fun to build, and quietly one of the more consequential things you could be
building right now.*

---

## TL;DR

- **Runes runs fleets of LLM agents** over a swappable message fabric
  (in-process ↔ MQTT 3.1.1 ↔ MQTT 5), with A2A for discovery and MCP for
  tools.
- **Every workflow verb is a plugin.** `cmd`, `ruby`, `chat`, `agent`,
  `map`, `repeat`, `call` — seven runes, between 68 and 693 lines each, all
  replaceable, and a new one takes about thirty lines.
- **It runs Shopify [Roast](https://github.com/shopify/roast) workflows
  unmodified.** The shipped example is Roast's README example, byte for
  byte, and the test suite reads that exact file.
- **It treats the boring parts as the product**: capability guard, signed
  envelopes, a durable journal, verify-and-resume, and a Rails observatory
  that watches the whole fleet.
- **12 146 lines of `lib`, 8 171 lines of tests, 455 tests, zero network in
  the suite.** Ruby 4.0.4, Rails 8.1.3.1, SQLite, mosquitto on localhost.

---

## 60 seconds: what it actually is

A workflow is a plain Ruby file that is `instance_eval`'d — no DSL gem, no
YAML, no graph builder:

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

```bash
bin/runes-workflow execute examples/analyze_codebase.rb
```

`cmd!(:recent_changes).lines` inside the agent block is a method call, not a
variable — inside a step, `self` *is* the step's input context. That single
design decision is why the syntax stays readable as workflows grow, and it
is Roast's, not ours.

Underneath, the same file drives a fleet over MQTT, where agents are
discoverable, addressable, and auditable:

```
runes/agents/<id>/card | status | tasks/<req>/response
runes/prompts                     ← broadcast work
runes/prompts/<req>/claim → started → progress → response
runes/tools/<tool>/request | response | error
runes/_log/prompts                ← durable journal
$a2a/v1/discovery/<org>/<unit>/<agent_id>
$a2a/v1/tasks/<org>/<unit>/<agent_id>
```

---

## Nine things that make this genuinely fun to build

**1. Deleting the clever part made it stronger.** 0.3 removed the entire
claim/lease consensus protocol — about 250 lines of "who gets this work?"
bookkeeping — and replaced it with MQTT 5 shared subscriptions. The broker
now does exactly-once distribution natively. We proved it live: 200
messages, two clients in one shared group, 100/100 each, no dupes, no
losses. **The lesson is the fun part: the best distributed-systems code is
the code you get to delete.**

**2. A hand-rolled MQTT 5 client, and it's only 899 lines.** The whole
adapter — CONNECT/CONNACK property probing, PUBLISH properties, `$share`
subscriptions, keepalive, reason codes — fits in one readable file with a
33-test codec suite behind it. Writing a wire protocol from the spec and
watching two processes talk is one of the purest joys in this trade.

**3. The transport is a seam, so the tests never touch a broker.** One
contract, three implementations: an in-process hub (used by every test), an
MQTT 3.1.1 adapter for maximum compatibility, and the MQTT 5 adapter. A
test can therefore assert *exactly-once dispatch across two agents* in
milliseconds, with no broker, no network, no flake. Swapping the fabric is
a constructor argument.

**4. A rune is a plugin, and it takes about 30 lines.** There is no
special-casing: `Runes::Plugin.names(kind: :rune)` returns the verb list,
and dropping a class in adds a verb to the DSL — no engine change:

```ruby
class Runes::Plugins::Greet < Runes::Rune
  plugin :greet, description: "Say hello"
  # Input / Output / Config + execute(input) → output
end
```

`greet(:hi) { "world" }` now works in every workflow, and inherits the
harness's furniture (journal, registry, observatory) because it is a
plugin, not a special case. This is the extension story of DSH applied to a
workflow DSL, and it is *satisfying*.

**5. We adopted another project's DSL, and made the docs unfakeable.**
Runes runs Roast workflows unmodified — matched in both directions,
including the absences (no `respond`, no `on_error:`, no `.roast/` config).
The discipline that follows is the fun part: `examples/analyze_codebase.rb`
*is* the Roast README example, and the compatibility test reads that file,
so the docs cannot drift from the artifact. When you use a feature and it
turns out your own README lied, you fix both — we did, twice, in one
afternoon.

**6. Reading a fleet is its own reward.** The Rails observatory subscribes
to `runes/#` and `$a2a/#` and reconstructs every agent's life: cards,
online/offline (including the broker's Last Will), prompt lifecycles, tool
calls, A2A handoffs. There is a specific moment of delight in opening a
browser and watching a handful of agents pass work to each other on a bus
you built.

**7. The tests are hermetic, and that's a craft, not a chore.** Provider
HTTP is faked with a real `Net::HTTPResponse` over a dup transport; the
agent CLI is replaced at a factory seam; the chat backend is injected; the
whole workflow suite runs with `command_runner=`, `provider_factory=` and
`backend=`. Consequence: **455 tests, 2 083 assertions, no API key, no
network, no broker required** — you can run the entire harness on a plane.
*(Round-5 audit found this was false: `test/second_audit_test.rb` dialled the
default MQTT port 1883. Fixed — it now spawns its own broker on a free port,
and the claim is verified: nothing in the suite reaches the network.)*

**8. Ruby is the right language for this, and it's not close.** Blocks with
`instance_exec`, `method_missing` delegation (so `ruby!(:x).anything` falls
through to the value), `define_singleton_method` binding a verb's
`X`/`X!`/`X?` triple per plugin, `Struct` value objects, `Mutex` +
`Thread` where Python would need a framework. The workflow DSL that results is small enough to
read in one sitting — mostly `instance_exec`, `define_singleton_method`
and good manners.

**9. The honest bits are fun too.** `parallel` uses threads instead of the
`async` gem — so, yes, a *running* iteration cannot be cancelled, and we
write that down. `cmd` inherits Roast's shell semantics for a single
command string; that's in the docs *and* in a test. Known gaps are first
class in `STATE.md`. Nothing builds trust faster than a project that tells
you where it's weak.

---

## Why this is more important than it looks

**1. Agents are becoming infrastructure, and infrastructure has
requirements.** A prompt loop is a demo. The moment an agent can write
files, run commands, spend money and talk to other agents, it needs what
every other piece of infrastructure needs: **identity, least privilege,
audit, and observability**. Runes is built with the guard, the journal, the
signatures and the observatory as the product — the model call is the easy
part. That inversion is the whole bet, and it's the right one.

**2. Non-determinism makes auditability a correctness property.** You
cannot reproduce an LLM run by re-reading the code. So every prompt
lifecycle — request, claim, start, progress, response, plan, tool calls,
verifier verdict — is appended to a durable, rotating, `flock`-protected
journal and published on the bus, and `bin/runes-replay` shows or replays
it. **Your agents' memory should live on your disk, in a format you can
read, not in a vendor's dashboard.**

**3. "It can do anything" is the threat model, not the feature.** A
default-deny capability guard decides per tool *and* per action
(`fs_read` / `fs_write` / `exec`) on the resolved path; tool RPC is off
unless explicitly enabled and authenticated with a shared secret compared
in constant time; `run_command` rejects path escapes; untrusted tools can
run in a real `ruby.wasm` sandbox with a fuel budget; `bin/runes-acl`
generates a fail-closed mosquitto ACL file so the *broker* enforces it too.
Layers, not vibes.

**4. On a shared bus, "unsigned" means "unknown", and unknown means
"could be anyone".** Ed25519 signed envelopes with a per-agent trust store
turn `agent_id` from a claim into a fact. Nothing else in the agent
ecosystem treats the message bus as an adversarial surface — and a fleet
where any process can impersonate any agent is not a fleet, it's a
free-for-all.

**5. Interop, or you're an island.** Two protocols, deliberately chosen:
**A2A** so other ecosystems can discover and task your agents, and **MCP**
so your tools are consumable by any MCP client (and vice versa). The
transport is swappable; the providers are pluggable; the workflow DSL is
Roast-compatible. **Adopting Runes doesn't lock you in — and that's the
point.** Tools that only work if you never leave are a trap; we'd rather
win on merit.

**6. Ruby deserves a first-class answer here.** The agent boom happened in
Python, and the Ruby community has been told, politely, to enjoy its
Rails-shaped past. That's nonsense. Ruby is *better* at the two things
agent systems actually are: **expressive DSLs** for describing work, and
**boring, reliable libraries** for running fleets. Runes is the argument,
in code, that Ruby is a serious choice for agent orchestration — not a
nostalgic one.

**7. Local-first is a political position as much as a technical one.**
SQLite, mosquitto on `127.0.0.1`, keys in a `.env` you control, no SaaS in
the request path. You can run the whole thing on a laptop on a plane, and
you can run it on your own broker with your own ACLs. For anything that
touches a company's source code, that is not a nice-to-have.

---

## Receipts

Because "trust me" is not marketing, here is what's actually in the repo
today:

| | |
| --- | --- |
| `lib/` | **12 146 lines** across 55 files |
| `test/` | **8 171 lines** across 34 files |
| Suite | **455 runs, 2 082-2 083 assertions, 0 failures** — no keys, no provider calls (one file dials a local broker: `doc5.md` D5-1) |
| Observatory | **61 runs, 348 assertions**, Rails 8.1.3.1 |
| Executables | **7**: `runes` (TUI), `runes-daemon`, `runes-client`, `runes-mcp`, `runes-replay`, `runes-acl`, `runes-workflow` |
| Workflow engine | **1 658 lines**, stdlib only — no `async`, no `ruby_llm` |
| The seven runes | **1 679 lines**: `agent` 693, `chat` 402, `map` 176, `cmd` 157, `repeat` 97, `ruby` 86, `call` 68 |
| MQTT 5 adapter | **899 lines**, hand-rolled, live-verified against mosquitto 2.1.2 |
| Dispatcher | **1 545 lines**, down from 1 968 after the fabric/journal/session split |
| Gem | builds clean — no secrets, no local state, all seven binstubs installed, MIT `LICENSE` shipped |
| Live proof | 200 messages, one MQTT 5 shared group, exactly-once, **ALL CHECKS PASSED** |

Run it yourself: `bundle exec rake test`, then
`bundle exec ruby demo/smoke.rb` (offline, no key), then
`bin/runes-workflow execute examples/analyze_codebase.rb`.

---

## What we're honest about

A pitch that hides the seams is a pitch you'll resent in a month. So:

- **Workflow runes don't consult the guard yet.** `cmd`/`agent` run
  directly, and a single-string `cmd` is shell-interpreted exactly as Roast
  does. That's documented in `docs/WORKFLOWS.md`, tracked as gap #1 in
  `STATE.md`, and queued: guard-aware runes, opt-in, because default-deny
  would break every unmodified Roast file.
- **`parallel` is threads, not `async`.** So there's no cooperative
  cancellation of a running iteration. We traded that for one fewer
  dependency and said so.
- **MQTT 3.1.1 is compatibility-only** — no shared groups, no properties.
  It refuses loudly rather than degrading silently.
- **The observatory has no auth**, so read access is a disclosure surface.
  It's fine on localhost today; it is a prerequisite for the "launch
  workflows from the browser" feature, not an afterthought.
- **One-shot tool feedback**: a single build plan does not yet loop
  plan→execute→feed-back. Missions compensate with verify-and-resume.

Every one of those is a `git grep` away from a doc and a test, which is the
point.

---

## Write a verb in 30 lines

The extension story, verbatim from `docs/WORKFLOWS.md` and exercised by
`test/plugin_test.rb`:

```ruby
class Runes::Plugins::Greet < Runes::Rune
  plugin :greet, description: "Say hello"

  class Input < Runes::Cog::Input
    attr_accessor :name
    def validate! = raise(InvalidInputError, "'name' is required") if name.nil?
    def coerce(value) = (super; @name = value.to_s)
  end

  class Output < Runes::Cog::Output
    attr_reader :text
    def initialize(text) = (super(); @text = text)
    def raw_text = text
  end

  def execute(input) = Output.new("hello #{input.name}")
end
```

No engine change. `greet(:hi) { "world" }` is now a workflow verb, it shows
up in `Runes::Plugin.names(kind: :rune)`, and it will appear in the
observatory's plugin catalogue as soon as that lands.

---

## Where this goes next

The next big unlock is making the observatory the fleet's **memory,
participant and oracle** rather than just a viewer:

- **A run console** — workflows become objects you can watch step by step,
  diff between runs, and re-run one failed scope of.
- **Identity badges and impersonation alerts** — the observatory can prove
  who published what, and shout when one `agent_id` shows up with two keys.
- **An observatory that is an agent** — its own A2A card and an MCP server,
  so any agent can ask *"what happened on the bus?"* mid-task.
- **Guard-decision telemetry** — see what the guard *refused*, not just what
  was published.
- **Record → replay → test** — capture a fleet conversation and replay it
  offline on the in-process hub, then turn it into a fixture.

The full proposal, with costs and risks, is in
[`docs/OBSERVATORY_ROADMAP.md`](OBSERVATORY_ROADMAP.md).

---

## The paragraph to steal

> Runes is a Ruby agent harness that treats the unglamorous half of agent
> infrastructure as the product: a swappable message fabric (in-process,
> MQTT 3.1.1, MQTT 5 shared subscriptions), A2A discovery, MCP tools,
> Ed25519-signed envelopes, a default-deny capability guard, a durable
> journal with verify-and-resume, and a Rails observatory that watches the
> whole fleet. Its workflow DSL is Roast-compatible — a Roast file runs
> unmodified — and every one of its seven verbs is a plugin you can replace
> in about thirty lines. Twelve thousand lines of library, eight thousand
> lines of hermetic tests, no network required, no vendor in the path.
