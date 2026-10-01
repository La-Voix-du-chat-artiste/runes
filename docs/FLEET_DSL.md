# Runes Fleet DSL — Specification

**Status:** Draft v0.1
**Target release:** runes 0.4.0
**Depends on:** the 7-rune workflow semantics (v0.3.0), `Runes::Transport` seam,
capability guard, MQTT 5 fabric
**Closes:** the "guard does not see runes" gap (`STATE.md`); the Spinel-AOT
deployment path for fleet files

---

## 1. Purpose

The 7 runes describe *computations*: lazy, memoized steps wired by explicit
references. They do not describe *organizations*: who the agents are, what
they may touch, how work flows between them, and what happens when the world
changes. A workflow `.rb` file is executable but not auditable — the guard
cannot reason about it before it runs.

The **Fleet DSL** is a declarative **world + rules** layer on top of the runes:

- **World** — the static topology: agents, models, tools, workspaces,
  channels, routes, facts, schedules.
- **Rules** — reactive behaviour: *when event E matches condition C, perform
  action A.*

It borrows the semantics of Inform 7 (a declared world; rules triggered by
change) without borrowing its surface (natural language). The surface is a
**restricted, statically analyzable subset of Ruby**, so the same language
describes both the DSL and the systems plumbing underneath it.

### 1.1 Non-goals

- Not a new runtime. The Fleet DSL **lowers onto the existing runes and the
  transport seam** (§9). No new execution engine.
- Not general-purpose Ruby. Fleet files trade expressiveness for
  auditability. Arbitrary computation stays in `ruby` runes and host code.
- Not a natural-language interface. Prose-to-fleet translation is the job of
  the existing LLM planner (the `/goal → /done` pattern), which emits Fleet
  DSL as its canonical, validated output form.

---

## 2. Design principles

| # | Principle | Consequence |
|---|-----------|-------------|
| P1 | **Declarative world, reactive rules** | World statements have no side effects at load; rules fire on events |
| P2 | **One language, two layers** | Fleet files are plain Ruby in a restricted subset; the host harness remains full Ruby |
| P3 | **Fail-closed loading** | Any unknown construct, unresolved name, or malformed expression aborts the load with a precise error. A fleet file that loads is fully analyzable |
| P4 | **Statically analyzable (Spinel path)** | The subset is chosen to be whole-program compilable by an AOT Ruby compiler (Spinel) without runtime reflection |
| P5 | **Lowers onto the 7 runes** | Every declaration and rule compiles to existing plugins (`:rune`, transport subscriptions, guard policy). The DSL adds zero new privileged code |
| P6 | **The guard sees everything** | Tool sets, routes and rule actions are extractable at load time into `policy.json` fragments and mosquitto ACL entries |

---

## 3. Definitions

- **Fleet file** — a single `.fleet.rb` document. Self-contained; the only
  inputs are its own declarations plus fleet-level parameters (§10).
- **Agent role** — a declared station in the topology. Distinct from a
  running process: one role may be served by N daemon processes (shared
  subscription) or one process may serve several roles.
- **Channel** — a named, typed endpoint on the transport seam (an MQTT topic
  pattern, an inproc name, or an A2A task address).
- **Event** — an immutable observation from the fabric: a PUBLISH matching a
  subscribed pattern, a presence transition (LWT), a lifecycle signal
  (mission started/failed, guard denial), or a timer.
- **Rule** — a triple *(source, guard, actions)*. Rules are data at load
  time, behaviour at run time.
- **Fact** — a fleet-scoped, typed constant or a guarded mutable cell that
  rules may read; facts are declared, never created dynamically.

---

## 4. World declarations

### 4.1 `fleet`

```ruby
fleet "prospection" do
  description "CRM pipeline: qualify contacts, draft outreach, review."
  transport :mqtt5                      # inproc | mqtt311 | mqtt5 | auto
  group     "prospection-prompts"       # shared-subscription group

  # ... agents, channels, routes, facts, rules
end
```

Semantics: exactly one `fleet` block per file. The block is evaluated once at
load time in a fixed binding — no `self` tricks, no `instance_eval` of foreign
code. `transport`/`group` delegate to the existing `Runes::Transport` seam.

### 4.2 `agent`

```ruby
agent :scraper do
  model   "deepseek-flash", variation: :high
  tools   fs_read: :allow, exec: { allow: %w[curl jq] }
  workspace "workspace/scraper"
  identity  "config/keys/scraper.pem"   # Ed25519 keypair (existing security/)
  concurrency 2                        # prompt worker pool for this role
end

agent :reviewer do
  model "deepseek-flash"
  tools :none                          # read-only observer: sees, never acts
end
```

Semantics:

- `tools` is **default-deny**. Absent tool ⇒ denied. This is the load-time
  counterpart of the runtime guard: the static policy extract (§8) is derived
  from exactly these clauses.
- `tools :none` is the explicit form of the empty set (never the implicit
  default — the default is *fail loudly*, see P3).
- `model` delegates to the existing `LLMClient` router; aliases and provider
  preference order are unchanged.
- Multiple `agent` blocks with the same id in one file = load error.

### 4.3 `channel`

```ruby
channel :qualified_contacts, "runes/events/contacts/qualified", schema: :contact_event
channel :dead_letter,        "runes/events/dead",               retain: true
```

Semantics: a channel binds a **symbolic name** (usable in rules and routes)
to a concrete transport address. `schema` names a JSON schema the payload is
validated against before any rule guard runs (fail-closed: invalid payload is
a `guard.denied`-style refusal event, never a rule firing on garbage).
Schemas are declared assets, not inline code.

### 4.4 `route`

```ruby
route :scraper => :writer => :reviewer
route :reviewer => :outbox, when: :accepted
```

Semantics: routes are **directed edges** in the fleet graph. They are (a)
documentation — the topology the observatory renders, (b) static validation —
a `task` action targeting an unknown role is a load error, (c) ACL material —
an edge :a → :b authorizes :a to publish on :b's task topic and nothing more.

`when:` is an optional guard over the producing event (same expression
language as §6); it partitions the edge by outcome.

### 4.5 `fact`

```ruby
fact :max_drafts_per_hour, 20
fact :outreach_tone, "professional"
```

Semantics: immutable constants, resolved at load. Mutable cells (`cell`
keyword, reserved for v0.2) are declared with an initial value, a type, and
optionally guards on writes. Facts may be referenced in rule expressions.

### 4.6 `schedule`

```ruby
schedule :weekly_report, cron: "0 9 * * MON"
```

Semantics: timers are events like any other (§5.1). Cron strings are static;
`interval 5.minutes`-style dynamic computation is reserved for host code.

---

## 5. Rules

### 5.1 Form

```ruby
on :contact_qualified,          # event source (channel, presence, lifecycle, timer)
   guard: ->(e) { e.score > 0.7 && e.country == "FR" }   # optional, restricted lambda (§6)
   then: [
     task(:writer, "Redige l'email pour %{contact} (ton: %{tone})",
          timeout: 120),
     publish(:metrics, { kind: "qualified", at: :now }),
   ]
```

Concrete surface (both spellings are sugar over the same triple):

```ruby
on(:contact_qualified) do |e|
  next! unless e.score > 0.7
  task :writer, "Redige l'email pour #{e.contact}"
end
```

### 5.2 Event sources

| Source | Fires when | Payload |
|--------|-----------|---------|
| `on :channel_name` | PUBLISH matches the channel's topic pattern, after schema validation | validated event object |
| `on :agent_online` / `:agent_offline` | retained status transition (Agent Card / LWT) | `{agent, role, at}` |
| `on :mission_failed` / `:step_failed` | lifecycle signals already on the journal/bus | `{mission, step, error}` |
| `on :guard_denied` | the capability guard refuses anything in this fleet | `{tool, action, resource, agent}` |
| `on :weekly_report` (schedule name) | timer | `{}` |

Unknown source name ⇒ load error (P3).

### 5.3 Evaluation semantics

1. **Order.** Rules are evaluated in declaration order. All matching rules
   fire; actions are enqueued in rule order. (Rejected alternative:
   first-match-wins — it makes rule files order-dependent in a way humans
   misread. Rationale recorded here for future debate.)
2. **Isolation.** A guard never mutates. A guard that raises is a load-time
   error if the failure is provable statically; otherwise it is a runtime
   refusal event (`rule_guard_error`), never a silent skip.
3. **Idempotency.** Every action carries a deterministic `request_id`
   (fleet, rule, event id). The existing `Runes::RequestLedger` dedupe
   applies: a redelivered event can never execute the same action twice.
4. **No fan-out explosion.** `max_actions_per_event` (fleet-level, default
   16) bounds total actions per event; exceeding it fails the event to the
   dead-letter channel.
5. **Determinism.** Same fleet file + same event sequence ⇒ same actions,
   same order. (Required for journal replay and for audit.)

### 5.4 Actions

| Action | Lowers to | Guard-visible? |
|--------|-----------|----------------|
| `task role, prompt, opts` | addressed A2A task envelope → existing `agent`/`chat` rune | yes — target must be on a declared route edge |
| `publish channel, payload` | transport PUBLISH on the channel's topic | yes — ACL-derived |
| `notify text, level:` | observatory/TUI event | yes |
| `spawn role, n:` | no-op in v0.1 (process orchestration stays outside); reserved | n/a |
| `set :fact, value` | reserved for mutable cells (v0.2) | will be yes |

Actions are the **only** way rules affect the world. No other side effects
exist in the DSL.

---

## 6. Expression language (restricted)

Guards, route `when:` clauses and string templates share one expression
language. It is a **whitelist**, not a blacklist:

- Literals: strings, numbers, booleans, arrays, hashes of literals.
- Access: `e.field`, `e[:field]`, nested access on validated schema fields.
- Comparison/arithmetic: `== != < <= > >= && \|\| ! + - * /`, string `match?`
  with a **static** regexp literal.
- Fleet facts: `fact(:max_drafts_per_hour)`.
- Time: `:now` (event receipt time — never wall clock inside guards).
- Templates: `"text %{field} more"` — bounded interpolation of validated
  event fields and facts only. Interpolated values are tainted for ACL
  purposes: a topic or tool name built by interpolation can only select
  among statically declared candidates (never free-form).

**Forbidden inside fleet files (non-exhaustive):** `eval`, `instance_eval`,
`class_eval`, `define_method`, `method_missing`, `const_missing`,
`autoload`, `send`/`__send__` with dynamic names, `require`/`load` of gems,
monkey-patching or reopening classes, `Singleton`, threads/`fork`, globals,
`system`/backticks (all process execution flows through declared `exec`
tool grants), open network calls (all I/O flows through declared channels),
`ObjectSpace`, `Binding`, `catch/throw` across rule boundaries.

Enforcement: the loader parses fleet files with a **restricted AST walker**
(Prism, already a Ruby 3.x dependency) that rejects forbidden nodes before
any evaluation. This runs identically in tests, in the interpreted harness,
and — later — as a conformance gate for the Spinel path.

---

## 7. Configuration & precedence

Fleet parameters may be supplied at load (`-- env=staging`), mirroring the
workflow engine's existing argument mechanism. Precedence, lowest to
highest:

1. built-in defaults
2. fleet-level `config` block
3. load-time arguments
4. per-declaration clauses

Same precedence ladder as the workflow engine's `global → general → regexp →
name` — one mental model for both layers.

---

## 8. Static analysis outputs

Loading a fleet file produces, in addition to the runtime object:

1. **Policy extract** — one merged view of every `tools` clause, in the same
   shape as `config/policy.json`. The guard consumes this extract for
   planner-driven and rule-driven actions alike. *This is the mechanism that
   closes the "guard does not see runes" gap for the declarative layer.*
2. **ACL extract** — per-role mosquitto `acl_file` fragment: exactly the
   topics a role publishes and subscribes, derived from channels, routes and
   rules. Fed to the existing `bin/runes-acl` generator; no catch-all allow.
3. **Topology graph** — agents + route edges + rule edges, in the same shape
   the observatory's `/topology` already renders.
4. **Determinism certificate** (test artefact) — for the conformance suite:
   a hash of the normalized fleet AST, recorded in the journal at boot.

---

## 9. Lowering onto the runes

The declarative layer compiles; it does not interpret.

| Fleet construct | Lowers to |
|-----------------|-----------|
| `agent` role | Agent Card publication + tool manifest registration (existing mechanisms) |
| `channel` | one transport subscription per channel (MQTT 5 shared where applicable) |
| `route a → b` | static validation + ACL edge + observatory metadata |
| `on :ch do ... end` | a `ruby` rune per rule (matcher) wrapping its actions as steps; `map` for per-item fan-out |
| `task` action | an `agent` (or `chat`) rune invocation, addressed through A2A topics |
| `publish` action | a `cmd`-free transport call; still journaled and observable like every rune |
| `schedule` | timer source feeding the same rule matcher |

Consequence: rules get journaling, replay, the observatory timeline and the
telemetry pipeline **for free**, because a rule *is* an ordinary rune in the
existing plugin registry (`kind: :rune`).

---

## 10. Errors and failure taxonomy

| Class | When | Behaviour |
|-------|------|-----------|
| `Fleet::LoadError` | parse/validation/static analysis failure | load aborts; zero subscriptions registered; zero partial world |
| `Fleet::SchemaError` | event fails schema validation | event refused, published to `:dead_letter`, counted on `runes/guard/denied` |
| `Fleet::GuardError` | action not permitted by static or runtime policy | action refused, `guard.denied` telemetry (existing sink) |
| `Fleet::ActionError` | lowered rune fails | existing rune semantics: `fail!` propagates; rule marked failed in journal; fleet keeps running |
| `Fleet::FanoutError` | action budget exceeded | event to dead-letter; fleet keeps running |

Load is atomic: a fleet file that fails analysis leaves **no** transport
subscriptions and **no** guard grants behind.

---

## 11. Conformance levels

| Level | Requirement | Gate |
|-------|-------------|------|
| L1 — Valid | loads, validates, runs on the interpreted harness | unit tests (hermetic suite, same dup-transport technique) |
| L2 — Auditable | §8 outputs (policy, ACL, topology) extractable and diffed in CI | golden-file tests + `bin/runes-acl` round-trip |
| L3 — AOT-ready | fleet file compiles under Spinel without boxed slow paths in rule matchers | CI job, allowed to be non-blocking while Spinel matures |

L1 and L2 ship in 0.4.0. L3 is a tracking goal: the restricted subset in §6
is *chosen* so that a L1/L2 fleet file is a L3 candidate with no rewrite.

---

## 12. Example: the prospection pipeline, as a fleet

```ruby
fleet "prospection" do
  transport :mqtt5
  group     "prospection-prompts"

  channel :contact_found,    "runes/events/contacts/found",    schema: :contact
  channel :contact_qualified,"runes/events/contacts/qualified",schema: :contact
  channel :draft_ready,      "runes/events/drafts/ready",      schema: :draft
  channel :metrics,          "runes/events/metrics"

  fact :max_drafts_per_hour, 20

  agent :scraper do
    model "deepseek-flash"
    tools fs_read: :allow, exec: { allow: %w[curl jq] }
  end
  agent :writer do
    model "glm-5.3-flash"
    tools fs_write: :allow
  end
  agent :reviewer do
    model "deepseek-flash"
    tools :none
  end

  route :scraper => :writer => :reviewer

  on :contact_found do |e|
    next! unless e.email.match?(/\A[^@]+@[^@]+\z/)
    task :scraper, "Enrichis #{e.email} et publie sur :contact_qualified"
  end

  on :contact_qualified do |e|
    next! unless e.score > 0.7
    task :writer, "Redige l'email pour %{name} (ton: professional)"
    publish :metrics, { kind: "qualified" }
  end

  on :draft_ready, guard: ->(e) { e.risk == :low } do |e|
    notify "Brouillon pret pour #{e.contact}", level: :info
  end

  on :guard_denied do |e|
    notify "Refus: #{e.agent} / #{e.tool} / #{e.action}", level: :warn
  end
end
```

---

## 13. Versioning and evolution

- The spec version (v0.1) is declared in the file header comment
  (`# fleet-spec: 0.1`) and enforced by the loader.
- Additive changes (new actions, new event sources) bump the minor; removals
  or semantic changes to evaluation order bump the major and require a
  migration note in `DEVELOPMENT_LOG.md`.
- `spawn` and mutable `cell` are reserved keywords in v0.1 (parse, error
  "reserved for v0.2") so early files never silently depend on undefined
  behaviour.

---

## 14. Open questions

1. **First-match vs all-match** (§5.3) — settled as all-match for v0.1;
   revisit after real fleet files exist.
2. **Rule priorities** — not in v0.1; if fan-out ordering becomes a problem,
   prefer an explicit `priority:` clause over declaration order.
3. **Mutable cells** — deferred to v0.2; interaction with determinism
   (§5.3.5) needs a write-ahead journal before it can ship.
4. **Nested fleets** (a fleet importing another fleet as a sub-topology) —
   deferred; import would be lexical and analyzable, never dynamic.
5. **Spinel gap tracking** — §6's forbidden list must be reconciled against
   Spinel's `docs/limitations.md` as both projects evolve; a conformance CI
   job is the mechanism.

---

*Spec status: draft for review. Next step: spike the restricted AST walker
(Prism) against `examples/prospect_pipeline.rb` to size the lowering work.*
