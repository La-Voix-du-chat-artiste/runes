# Runes Observatory — what to build next

A proposal for extending `runes_observer/` (the Rails 8.1 app) to exploit
everything 0.3.0 added — the transport seam, shared-subscription fabric,
A2A, MCP, identity/signatures — and everything Phase 17 added, the seven
**Runes** and the workflow engine.

Written as a proposal, not a plan of record: each item names what it costs,
what it risks, what it depends on, and how I would prove it works.

---

## 1. Where the app is today

Honest snapshot, so the proposals are grounded:

| | |
| --- | --- |
| **Surface** | `/` dashboard, `/agents` + `/agents/:agent_id`, `/packets` (filterable feed), `/interactions/:id` (one request/lease), `/feed` + `/feed/stats` JSON polled by a Stimulus controller every 2.5 s |
| **Ingest** | a separate process (`bin/runes-ingest`) subscribed to `runes/#` **and** `$a2a/#` with the `mqtt` **0.7** gem — i.e. **MQTT 3.1.1**, so no properties are visible |
| **Storage** | `agents` (card, state, first/last seen), `packets` (topic, kind, agent_id, request_id, lease_id, event, tool, payload, bytes, occurred/received), `ingest_statuses` (singleton health row) |
| **Retention** | `RUNES_OBSERVER_RETENTION_DAYS` (7) + `RUNES_OBSERVER_MAX_PACKETS` (200k), pruned every 1 000 packets |
| **Tests** | 61 runs / 348 assertions, controller + integration level, plus a `DemoFabric` seeder |
| **Missing** | no auth, no write path, no jobs/ActionCable, no notion of "abnormal", no workflow/rune awareness, no signature verification, no MQTT 5 metadata |

**The thesis.** The observatory is currently a *viewer*: it can show you
packets after the fact. The new features make three other roles possible,
and they are where the value is:

1. **Memory** — runs, cards, traces and costs become durable objects with
   history and diffs, not a scrolling log.
2. **Participant** — it can answer questions over MCP/A2A, and it can
   *start* work, not just watch it.
3. **Oracle** — it can verify identity, enforce budgets, and fail a CI run
   when the fabric misbehaved.

Everything below is in service of those three.

---

## 2. Prerequisites (do these first, they block everything)

**PR-1 — the observer must depend on the harness — ✅ RESOLVED (Phase 25),
by a load path rather than a gem dependency.** `runes_observer/` now puts the
sibling checkout's `lib` on the load path (`config/initializers/runes_transport.rb`,
`RUNES_HARNESS_LIB` overrides) and the ingest subscribes through
`Runes::Transport`. Deliberately *not* `gem "runes", path: ".."`: the harness
declares `mqtt ~> 0.7` as a runtime dependency, and the observatory must not
pin — or be pinned by — the client its own transport may not use. The split is
preserved: only the ingest process loads the transport stack, so a harness
crash cannot take the UI down with it.

**PR-2 — telemetry seams.** The workflow engine and the guard currently
have no event hook (verified: nothing in `lib/runes/workflow*` emits
anything), and the observer has no workflow vocabulary at all. O1.1, O1.2,
O2.3 and O2.5 need small, additive seams — each is ~20 lines and does not
change behaviour:

```ruby
Runes::Workflow.telemetry = ->(event) { ... }   # on run/step boundaries
Runes::Capabilities::Guard.on_decision = ->(d) { ... }   # allow/deny
```

**PR-3 — write actions need auth.** Any "launch a workflow from the UI"
item (O1.2) is a **remote execution feature** and the app has no auth at
all (already recorded as a gap in `STATE.md`). Auth is not optional for
O1.2; the read-only items are unaffected.

---

## 3. P0 — make the observer see what the fleet actually sends

Small, unglamorous, and the highest value per line. None of these change
the UI's shape much, and all of them unblock the P1 work.

### O0.1 Ingest through `Runes::Transport` (uses P0.1) — ✅ DONE (Phase 25)

**Why.** The fabric now carries MQTT 5 properties — `response_topic`,
`correlation_id`, `user_properties` — and the observer could not see any of
them, because `mqtt` 0.7 speaks 3.1.1. It was also a second, divergent MQTT
implementation in a project whose P0.1 work was *deleting* exactly that. The
observer should consume the fabric through the same seam as the fleet: that
is the strongest possible dogfood of `Runes::Transport`.

**How it landed.** `MqttIngest` is gone; `FabricIngest` subscribes through
`Runes::Transport.build` to `runes/#` and `$a2a/#`, and hands each
`Runes::Transport::Message` to `PacketRecorder.record(topic:, payload:,
retained:, qos:, properties:)`:

```ruby
transport.subscribe(@topic)    { |message| consume(message) }
transport.subscribe(A2A_TOPIC) { |message| consume(message) }
```

Two deliberate details beyond the sketch:

- **Layered reconnection, not duplicated.** A transient drop is the
  adapter's business (MQTT 5 reconnects and re-subscribes on its own and
  reports through `on_health`, which `FabricIngest` mirrors into
  `IngestStatus` *and* into the retained-replay dedupe window); a drop that
  outlasts `DISCONNECT_GRACE_S` is ours, and triggers the rebuild/backoff.
  Without that split the observer's backoff would fight the adapter's.
- **The harness is put on the load path by an initializer**
  (`config/initializers/runes_transport.rb`), not by a gem dependency:
  `runes` declares `mqtt ~> 0.7` as a runtime dep, and the observatory must
  not pin — or be pinned by — the client its own transport may not use.
  `RUNES_HARNESS_LIB` overrides the path.

**Bonus, delivered:** `RUNES_TRANSPORT=inproc` runs the observatory with
**zero broker**, and that is now how the ingest tests drive it — a real
transport and a real recorder, no fake client.

**Acceptance, verified live** (mosquitto 2.1.2, `RUNES_TRANSPORT=mqtt5`):
`scripts/mqtt5_observer_probe.rb` published one A2A-shaped message and the row
came back with `correlation_id`, `response_topic`,
`user_properties = {"a2a-status":"working","probe-tag":…}` and
`ingest_statuses.transport = "MQTT5"`. The `qos` column stores the **delivery**
QoS: the ingest subscribes at QoS 0, so a QoS 1 publish arrives as 0 and is
stored as 0, which is the honest number for "what we received".

### O0.2 Widen the schema and the classifier — 🟡 MOSTLY DONE (Phase 25)

| Column | Source | Status |
| --- | --- | --- |
| `qos`, `retain` | `Message` | ✅ |
| `correlation_id`, `response_topic` | properties | ✅ (`correlation_id` indexed — it is the join key that survives an unparseable payload) |
| `user_properties` (JSON) | properties | ✅ bounded: 32 pairs, 512 bytes per value, truncated per value so the stored JSON always parses |
| `signature_state` | O0.3 | ✅ `unsigned`/`verified`/`untrusted`/`invalid` |
| `key_fingerprint` | O0.3 | ✅ indexed; impersonation is derived from it |
| `run_id`, `rune`, `step_index`, `duration_ms` | O1.1 | ✅ (`run_id` in Phase 20; the rest live in `workflow_steps`) |
| `tokens_in`, `tokens_out`, `cost_usd` | O2.5 | ✅ (`workflow_steps`) |

The classifier still does not know the A2A task space: `runes/a2a/tasks/…`
classifies as `other` (the live probe showed exactly that). `$a2a/#` topics
are recognised; the `runes/a2a/…` spelling is not, and should be either
classified or removed from the vocabulary.

### O0.3 Verify signatures, and catch impersonation (uses P1.5) — ✅ DONE (Phase 27)

**How it landed.** `ObserverSignature.check` runs on every parsed payload and
records two columns: `signature_state` and `key_fingerprint`.

| State | Means |
| --- | --- |
| `unsigned` | no `sig`/`alg`/`kid` — most fabric traffic, or a payload we cannot parse |
| `verified` | the Ed25519 signature checks out against a key in the trust store |
| `untrusted` | signed with a key the store does not hold (`:unknown_key`). The claim may be honest, but nothing here can confirm it |
| `invalid` | provably wrong: `:bad_signature`, `:malformed` |

`verify!` is called with `require_fresh: false` on purpose: freshness and replay
matter when a message is about to *cause work*, while the observer is a witness
and a stale-but-authentic packet is still authentic history — a replay guard
would also make the verdict depend on read order. The trust store comes from
`RUNES_OBSERVER_TRUST_DIR`, then `RUNES_TRUST_DIR`, then
`<harness>/config/trust`, and a missing directory is an *empty* store, so
signed traffic reads `untrusted` rather than trusted. Verification is memoized
per `(kid, digest)` because retained packets are re-verified on every reconnect.
A verifier exception is recorded as `invalid`, never as trust. An empty trust
store cannot distinguish a forgery from a stranger, and says `untrusted`.

`ImpersonationDetector` derives two findings from stored packets (so they
survive a restart): **split identity** (one `agent_id` with two fingerprints) and
**wrong key** (the fingerprint is not the one the trust store holds for the
claimed agent). The dashboard's Security panel shows the hour's counts,
impersonation findings with both fingerprints, and — under
`RUNES_OBSERVER_REQUIRE_SIGNATURES=1` — how many packets are unsigned, because
an unproven `agent` field should not be quiet. Packets are badged in the feed
(signed only, so an unsigned majority is not noise), labelled in full on the
packet page, and each agent page lists the keys it has been seen with.

**Acceptance met:** signed/unsigned/tampered/unknown-key fixtures assert all
four states; the memo is proven to verify once; a two-key fixture raises the
impersonation finding; a broken verifier reads `invalid`; controller tests cover
the panel, the badge and the agent key list. **Verified live** against mosquitto
2.1.2: `RUNES_PROBE_SIGN=1 ruby scripts/mqtt5_observer_probe.rb` published a
signed envelope and the stored row came back `verified` with the signing key's
fingerprint.

### O0.3 (original proposal)

**Why.** `PacketRecorder` currently trusts the payload's `agent` field. With
`Runes::Security::Envelope` and a `TrustStore` on disk, the observer can
say which packets are *provably* from whom — and `agent_id` reuse with a
different key is the single most interesting security event on a shared
broker. No other component in the project is better placed to notice it.

**How.** In the ingest path:

```ruby
if Runes::Security::Envelope.signed?(data)
  Runes::Security::Envelope.verify!(data, trust_store)   # raises on bad sig
  state = trust_store.trusted?(agent_id) ? "verified" : "untrusted"
else
  state = "unsigned"
end
```

Memoize verification per `(kid, payload digest)` — a busy fabric will
re-verify the same retained packet on every reconnect.

**UI.** A badge per packet and per agent; a new alert (O1.5) when one
`agent_id` publishes under two fingerprints, or when a signed packet fails
verification. A `RUNES_OBSERVER_REQUIRE_SIGNATURES=1` mode that flags
unsigned traffic loudly is the natural staging step towards the fleet-wide
`RUNES_REQUIRE_SIGNATURES`.

**Size** M · **Risk** low · **Acceptance** signed/unsigned/tampered
fixtures assert the four states; a two-key fixture raises the impersonation
alert.

### O0.4 Retention and rollups at real volume

> **Corrected after measurement (round-5 audit).** The premise below was
> wrong: at the stated cap `prune!` costs 0.4-2.2 ms and a cold `delete_all`
> ~1 s, so "a full `Packet.count` every 1 000 packets" is *not* what breaks
> first. The observatory's real limits are payload bytes shipped on every
> poll (`/feed` can return 50 MiB; doc5.md O5-2) and unbounded per-agent
> rendering (`/agents/:id` at 49 MB / 3.8 s; O5-4). Do those two first.

Pruning already exists, but there is no aggregate view, so the dashboard's
`Packet.since(5.minutes.ago).count` and `group(:kind).count` are computed
against the raw table.

**How.** Add a `packet_rollups` table (`minute × kind × agent_id → count,
bytes, errors`) written by the ingest process every minute; the dashboard
reads rollups for anything older than an hour, raw packets for the live
tail. Keep `prune!` bounded (`limit` + `delete_all` in batches) and move it
out of the ingest loop so a wedged ingest cannot stop retention.

**Size** M · **Acceptance** seed 200k packets, assert the dashboard's query
count and timing do not grow with table size, and that pruning never
deletes a packet belonging to an interaction that is still "open"
(a prompt with no response).

### O0.5 Ingest health: lag, reconnects, drops — ✅ DONE (Phase 26)

`IngestStatus` knows connected/disconnected and a packet total. The dashboard
pill now also answers the question an operator actually has — *"is this feed
trustworthy right now?"*:

- `reconnects` — counted both when our loop rebuilds the transport and when the
  adapter reconnects itself (the number exists to show how choppy the link is,
  not who fixed it);
- `drops` — `packets_dropped`, already there;
- `last_lag_ms` — the newest packet's **publisher** clock against our receipt.
  Getting this required the recorder to *believe a payload's own clock*
  (`at` on a journal entry, `ts` on a signed envelope) instead of always
  stamping `occurred_at = received_at`; a clock is accepted only when
  plausible (≤60 s future, ≤7 days old), and `nil` means "the publisher sent
  no clock", which is honest where `0` would be a lie;
- `packets_per_minute` — derived from the `packets` table, not from a counter
  that a reconnect resets.

The panel warns in red past `LAG_WARN_MS` (30 s). **Acceptance met:** unit
tests on every counter, a controller test that a 45 s lag renders as a warning
and that "no clock" says so instead of showing zero.

### O0.6 The observer must never join a work group — ✅ DONE (Phase 26)

Shared subscriptions mean a subscriber in the same group **steals work**, and
since O0.1 the observer subscribes through the very same API as the agents.
`FabricIngest#assert_not_a_worker!` inspects its own live subscription set
after subscribing and raises `WorkGroupRefusal` — naming the offending filter —
if any subscription carries a `group:` or a `$share/` filter. Two tests: the
real inproc ingest must expose exactly `runes/#` and `$a2a/#` with no group
(the live set, not a stub), and a deliberately grouped transport must be
refused with a message that explains what would have happened.

### O0.7 Tail `log/journal.jsonl` as a second source — ✅ DONE (Phase 26)

`JournalTail` follows one path, tracks inode + byte offset, emits only complete
lines (`MAX_LINE_BYTES` 64 KiB bounds a line that never ends), and re-reads
from zero on rotation or truncation. It is wired into the ingest's timer
threads (like pruning) so it does not depend on the broker.

The interesting part is the **cross-source check**: before storing a line it
asks whether that exact `(topic, payload)` row already exists. That is what
makes the two sources safe to run at once — an entry the observer heard on
`runes/_log/prompts` is not stored twice when the file is read, and a restart
re-reading the whole file cannot duplicate rows either. Off by default in
tests (`RUNES_OBSERVER_JOURNAL=off` in `test_helper.rb`, so the suite never
tails the developer's real journal); the default path is the sibling harness
checkout's journal and is only used when that file exists. An explicit path is
waited for, because an operator who names a file means it.

**Acceptance met:** read-once-in-order, partial lines, rotation, truncation,
an unstoreable line (counted, next one still lands), an unbounded partial line,
and a malformed line that is *stored* rather than dropped — the MQTT path's
behaviour, since silently discarding what we cannot parse is how a partial
outage becomes invisible.

---

## 4. P1 — the flagships

### O1.1 Workflow runs as first-class objects (uses Phase 17)

**This is the one I would build first if only one thing gets built.**

Today the observatory is structurally blind to the newest, most interesting
thing in the project: a Roast-compatible workflow runs in-process and
publishes nothing. Nobody can see a run except by reading stdout.

**How — the seam.** One additive hook in the engine:

```ruby
# lib/runes/workflow/workflow.rb + execution_manager.rb
Runes::Workflow.telemetry = ->(event) { Runes::Telemetry.publish(event) }
# event = { run_id:, workflow:, scope:, rune:, name:, step_index:, status:,
#           started_at:, duration_ms:, input:, output:, error:,
#           tokens_in:, tokens_out:, cost_usd: }
```

and a `Runes::Telemetry::TransportSink` that publishes each event on
`runes/workflows/<run_id>/<event>` through the same `Runes::Transport` the
rest of the fleet uses. That keeps the engine dependency-free (telemetry is
`nil` by default) and gives the observatory the events as ordinary packets.

**How — the app.** `WorkflowRun` (`run_id`, workflow file, params, status,
started/finished, duration, cost) and `WorkflowStep` (`run_id`, scope, rune,
name, index, status, duration, input, output, error). Pages:

- `/runs` — every run, newest first, with status and cost; filterable by
  workflow and by agent.
- `/runs/:id` — the step timeline: a row per rune showing **duration,
  input, output and error**, with the `cmd → agent → chat` data flow
  visible as it happened. A failed step shows the exception and the run is
  marked failed. Two runs of the same file can be **diffed step by step**
  ("the review step got slower, and this output changed").
- Each run links into the existing interaction timeline, so "a workflow ran"
  and "what the fabric saw" are one story.

**Acceptance** run `examples/analyze_codebase.rb` through
`bin/runes-workflow` with the sink enabled and faked providers: the
observatory shows exactly three steps, their timings, the cmd output
reaching the agent input, and the agent response reaching the chat input;
a deliberately failing step marks the run failed with the error text.

**Size** L (engine seam S + app L) · **Risk** low (additive) — this is the
biggest single win available.

### O1.2 Launch, re-run and fork from the UI (uses Phase 17 + P0.2)

Once runs are objects, the observatory can *start* them: a form choosing a
workflow from an allowlisted directory with targets and `key=value` params,
published on `runes/workflows/requests`; a small runner process executes it
under a capability policy and emits the same telemetry as the CLI.

The genuinely useful part is not "start" but the three variants:
**re-run** (same file, same params), **fork** (edit params — the workflow
vocabulary makes this meaningful), and **re-run one scope** (Roast's
`run:` makes "run just the review step again" a first-class operation,
which is exactly what you want when step 3 failed).

**Hard prerequisites:** PR-3 (auth) and the runes-guard gap
(`docs/WORKFLOWS.md` § *Not yet done: the guard does not see runes*). A UI
that can launch unguarded shell commands from a browser is not shippable —
the runner must consult the guard, and the allowlist must be explicit.
**Size** L+ · **Do not start before auth and guard-awareness land.**

### O1.3 Fleet topology and the A2A view (uses P0.3) — **built, Phase 21**

The observer sees discovery cards and A2A tasks but shows them as rows. A
**topology page** — nodes for agents, directed edges for discovery and
delegation, width by task count, colour by failure rate, latency on hover —
turns a packet list into an answer to "who is talking to whom, and who is
struggling?". Add **card revisions**: store a snapshot whenever a card
changes, so "when did this agent lose the `write_file` capability?" becomes
a diff instead of a guess. And a capability search over `tools` ("who can
do `run_command`?").

**Size** M · **Acceptance** two demo agents with a delegation produce one
edge with the right counts; a changed card produces a second revision and a
visible diff.

### O1.4 Trace waterfall, export, and a CI oracle — **waterfall built, Phase 21**

`/interactions/:id` groups a request correctly but reads as a list. Make it
a **waterfall**: one bar per packet, positioned by `occurred_at`, so gaps
and stalls are obvious (a 30 s LLM call *looks* like 30 s). Show the MQTT 5
metadata once O0.1 lands. Then two exports that make the observatory
useful outside a browser:

- **`/interactions/:id.json`** — the whole trace as one document, attachable
  to a bug report.
- **OpenTelemetry-shaped export** — spans named `runes.<kind>`, so an
  existing APM can ingest Runes traces. Interop is the project's whole
  positioning; this is the cheapest way to honour it.

And the sleeper feature: **`GET /api/v1/health.json` as a CI oracle** —
"after this integration run, assert there were zero unsigned publishers,
zero guard denials, and zero orphaned prompts". The observatory becomes the
thing your test suite asks about the fleet.
**Size** M · **Acceptance** a seeded trace renders bars with correct
durations; the JSON export round-trips; a CI-style request returns
counters.

### O1.5 Alerts: give the app a notion of "abnormal"

Right now nothing ever looks wrong. `Alert` (kind, severity, subject,
first/last seen, count, acknowledged) plus detectors that run in the ingest
process — no job runner needed:

| Detector | Fires when |
| --- | --- |
| impersonation | one `agent_id` publishes under two fingerprints (O0.3) — ✅ derived, not yet an `Alert` row |
| signature failure | a signed packet fails verification |
| orphaned request | a `prompt` with no `response` after N minutes |
| task timeout | an A2A task with no terminal status |
| agent flap | online/offline cycling more than N times in M minutes |
| backlog | shared-group queue depth or lag above threshold (P0.2) |
| cost spike | spend per hour above budget (O2.5) |

Dedupe by `(kind, subject)`, count occurrences, ack from the UI, and a badge
in the layout. **Size** M · **Acceptance** each detector has a fixture that
fires it and one that must not.

### O1.6 Plugin and rune catalog, generated from the registry

A `/plugins` page that renders `Runes::Plugin.all(kind:)` — name, kind,
description, class, source path — straight from the registry, plus a
"capability coverage" table comparing what the *fleet advertises* in cards
against what this harness *has*. It is nearly free (the registry already
carries descriptions), it makes the "a rune is a plugin" idea concrete, and
it doubles as documentation that cannot go stale — the same trick as the
shipped example file being the one the tests read.

**Size** S · **Acceptance** a controller test asserts the seven runes and
their descriptions render.

### O1.7 "Why did it do that?" — the plan chain

The mission/build pipeline publishes plans, tool requests, progress events
and verifier verdicts as separate packets; reconstructing the causal chain
by hand is the most common thing a human wants to do with this data. A
`/interactions/:id#plan` view that joins *prompt → plan → tool calls →
evidence → verifier verdict* turns the observatory from a packet viewer
into a debugging tool for the actual failure mode the project has
(one-shot tool feedback, per `STATE.md` gap 2).
**Size** M · **Acceptance** a seeded mission renders the chain with the
verifier's verdict and the evidence it saw.

---

## 5. P2 — bigger bets

### O2.1 The observatory as an agent (uses P0.3 + P1.4)

Publish an A2A card for the observer itself via
`Runes::A2A.discovery_topic(org:, unit:, agent_id:)` and ship
`bin/runes-observer-mcp`, an MCP server exposing read-only tools:

```
fleet_status()                      agent_card(agent_id)
recent_packets(kind:, agent_id:, since:, limit:)
trace(request_id)                   runs(workflow:, since:)
run_steps(run_id)                   search_packets(q)
```

Then the TUI, `runes-client`, or any agent can ask the fabric *"what
happened?"* in the middle of a task, and the observatory appears in
`bin/runes-client --agents` like any other participant. It is the clearest
possible demonstration that A2A and MCP are not decoration — and it makes
the MCP *client* path (not just the server) earn its keep.
**Size** L · **Risk** medium (an agent that answers questions needs
authorization boundaries; read-only tools only, no publish).

### O2.2 MCP session tracing (uses P1.4)

MCP is stdio, so none of it is on the bus: a failed tool call over MCP is
invisible today. An optional hook in `lib/runes/mcp/{server,client}.rb` that
publishes `runes/mcp/<session>/{request,response,error}` (with payload
redaction by default) gives the observer an MCP inspector — the "MCP, both
directions" feature becomes observable. **Size** M · **Risk** low-medium
(new seam; must default to off).

### O2.3 Guard-decision telemetry — ✅ DONE (Phase 28)

The observatory could show what was *published* but not what was *refused* —
which is the more security-relevant half (S4-1/S4-2 class findings were all
about refusals that did not happen).

**How it landed.** `Runes::GuardTelemetry` is the seam, shaped exactly like
`Runes::Telemetry`: a *sink* decides what a decision is worth, `record` builds
`{tool, action, resource, phase, agent, at}`, and the `TransportSink` publishes
it on `runes/guard/denied`. The capability guard reports every denial from
`log_deny` (the *log line* stays deduplicated; the event does not, because how
often a refusal happens is the thing an operator wants to see), the dispatcher
attaches a sink to its transport automatically, and `bin/runes-workflow`
reports `RUNES_WORKFLOW_POLICY` refusals on the same topic through the same
transport its run telemetry uses.

Two decisions worth naming: `Guard#allowed?` takes `report:` so the workflow
policy — which knows it refused a *rune* and reports that itself with
`phase: "workflow"` — does not produce two events for one refusal; and
emitting is rate-capped at `MAX_PER_MINUTE` because a guard that can be turned
into a denial amplifier is a worse bug than a missing event. A raising sink is
swallowed like every other telemetry path.

`/security` is the page: refusals per hour/24 h/all-time, a 30-minute refusal
sparkline, top tools and agents with filters, every row linking to the packet
that recorded it, and the signature verdicts/impersonation findings from O0.3
beside them — *who published* and *what was blocked* on one page. The dashboard
keeps a compact summary and links here. The classifier maps the topic to
`guard_denied` and the parent suite's topic-contract test carries a
representative topic for it, so the two halves cannot drift.

**Acceptance met:** telemetry unit tests (payload shape, truncation, raising
sink, the flood cap, guard integration, workflow-policy integration, `attach`
not overriding a chosen sink), classifier tests for the new topic including the
exact-match edge cases, and controller tests for the page (counts, filters,
drill-down links, empty state, signature findings). **Verified live:** with the
ingest on mosquitto, `scripts/guard_denial_probe.rb` published a refusal that
the observer stored as `guard_denied`. **Size** M · **Risk** low.

### O2.4 Flight recorder: replay a whole fleet conversation offline

`Runes::Transport::InProcess` is a real, tested hub. Feed it a recorded
packet stream (from `packets`, or a JSONL export) and you can re-run a
fleet conversation deterministically — perfect for regression tests and for
reproducing a production incident without a broker. This is the natural
marriage of the journal (P1.6), the transport seam (P0.1) and the hermetic
test discipline: **record in production, replay in CI**.
**Size** L · **Risk** medium (timing/ordering semantics must be pinned).

### O2.5 Cost and budget governance

`Agent::Stats`/`Usage` and the chat backend already produce tokens and cost.
Aggregate per run, per agent, per provider and per day; chart it; set
budgets; and let the runner (O1.2) **refuse** to start a workflow whose
budget is exhausted. "The observatory can say no" is a much more
interesting product than a dashboard chart.
**Size** M-L · **Depends on** O1.1 (events) and O1.2 (enforcement point).

### O2.6 Make it a mountable engine (uses P2 packaging)

The app is 34 files and ~1 950 lines with no host-app assumptions. Extracted
as `Runes::Observer::Engine` with namespaced models, a `bin/runes-observer`
binstub and an install generator, any Runes user could write:

```ruby
mount Runes::Observer::Engine => "/runes"
```

That is the packaging story (P2) applied to the app, and it is the same
move that made the harness installable. Cheap relative to its reach — the
work is namespacing, a migration generator and route isolation, not new
features. **Size** M-L · **Risk** medium (schema ownership in a host app).

### O2.7 Record → test

Turn any captured trace into a **fixture**: the packets plus the seams
(`Cmd.command_runner=`, `Agent.provider_factory=`, `Chat.backend=`) so a
production conversation becomes a hermetic test. This makes the observatory
a generator of the project's own test suite, and it is the only proposal
here that directly improves the *other* half of the repo.
**Size** M · **Risk** low.

### O2.8 Swarm theatre and the kiosk

A canvas force-graph of agents with message particles, animated from the
existing `/feed` (no new backend), plus a `/wall` kiosk page and a
time-travel scrubber over the rollups (O0.4). This is the demo-and-talks
feature: it is the thing that makes someone stop scrolling at a conference.
Cheap, and honest about being chrome — build it last.
**Size** M · **Risk** low.

---

## 6. Deliberately not proposed

- **Replacing an APM.** The OTel *export* (O1.4) is worth it; becoming a
  tracing backend is not.
- **Multi-broker fleet federation.** One broker per observer keeps
  `IngestStatus` and the topic grammar honest.
- **LLM summarisation of the feed.** It would be fun and it would be the
  least trustworthy thing in the app.
- **A write path into the fabric before auth.** See PR-3: the read-only
  features do not need it, and the write ones must not ship without it.

---

## 7. If I build one slice (about a week)

1. **O0.1 + O0.2** — ingest through `Runes::Transport`, persist properties
   and the new columns. *(Everything downstream is easier once the observer
   sees the real message.)*
2. **O1.1 + the engine telemetry seam** — `/runs` and `/runs/:id` for
   `examples/analyze_codebase.rb`. *(The visible payoff.)*
3. **O0.3** — signature state, fingerprints, impersonation alert.
   *(The single highest-value security observation available.)*
4. **O1.6** — the plugin/rune catalog. *(Nearly free, and it advertises the
   thing we just built.)*

That slice leaves the two suites green, adds no browser-side write
capability, and produces something worth demoing: *run a Roast workflow,
then watch it and verify who did what.*

## 8. Open questions for you

1. **Which role first** — Memory (runs/traces), Participant (MCP/A2A), or
   Oracle (signatures, budgets, CI)? They share prerequisites but diverge
   after that.
2. **Is coupling the ingest process to the `runes` gem acceptable?**
   I believe yes (it is the same repo, and it deletes a dependency), but it
   does mean a harness regression can break ingest — worth a conscious
   decision.
3. **Do you want the observatory to be mountable** (O2.6) in the 0.4 line,
   or stay a standalone app for now?
4. **Auth**: needed only for O1.2, but if the observatory is ever pointed at
   a shared broker, read access is a disclosure surface too.
