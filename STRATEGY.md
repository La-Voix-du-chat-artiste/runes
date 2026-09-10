# Runes — strategy, niche and the 0.3 reset

This is the "why" document: what Runes is betting on, what it deliberately
is not, and what changed in the 0.3 series. The how-to lives in
`README.md`; this file is the positioning.

## The 30-second pitch

**Runes is a sandboxed, auditable agent-execution fabric for local-first
fleets.** Agents plan, a default-deny capability guard decides what may
run, tools run in a WASM sandbox, every step is journalled, and a Rails
observatory shows the whole fleet — live and historical — down to the raw
MQTT payload. It speaks standard protocols (A2A for agents, MCP for tools)
and treats the message bus as a pluggable transport.

## What we are NOT competing on

- **Not "another agent framework".** LangGraph, CrewAI, the Claude/OpenAI
  agent SDKs and (in Ruby) Shopify's Roast already own *authoring agent
  graphs*. Runes does not try to be a nicer way to write a prompt chain.
- **Not an LLM SDK.** `ruby_llm` (and friends) own provider plumbing; the
  0.3 series keeps a thin built-in router but exposes an adapter seam so the
  community library can be plugged in (`RUNES_LLM_ADAPTER=ruby_llm`).
- **Not a broker.** The embedded MQTT broker remains a dev convenience.
  Production points at mosquitto/EMQX.

## The moat (in order)

1. **Fail-closed verification with evidence + resume.** `/build <mission>`
   runs one todo at a time: plan → execute through guarded tools → a strict
   QA verifier judges the acceptance criteria against the *raw* tool
   evidence → the sidecar and markdown are ticked atomically. A failed todo
   stops the run; re-running resumes where it stopped. Nothing else in the
   Ruby ecosystem does this, and most Python frameworks leave verification
   to the user.
2. **Isolation that is actually a boundary.** Tools execute inside
   `ruby.wasm` (WASI, fuel + wall-clock caps) and the capability guard is
   default-deny on both the planner path and the direct-RPC path. The
   command runner is path-confined, process-group-killed and env-scrubbed.
3. **Observability as a first-class feature.** The Rails observatory
   (`runes_observer/`) records every packet, reconstructs per-agent
   interaction timelines, and shows running/stale/ended agents. Debugging a
   fleet is normally guesswork; here it is a web page.
4. **Protocol citizenship.** A2A-over-MQTT discovery/tasks, MCP tools in
   both directions, and MQTT 5 shared subscriptions instead of a home-grown
   consensus algorithm.

## Where MQTT fits (and where it does not)

MQTT is the right *fabric* for local-first, many-peer, flaky-link fleets:
broadcast fan-out, retained last-known state, LWT presence, low bandwidth.
It is a poor place for coordination primitives, which is why the 0.3 series
deleted the claim/lease protocol in favour of MQTT 5 **shared
subscriptions** (`$share/<group>/<topic>`), Response Topic/Correlation
Data for replies, and User Properties for presence/trace — the same shape
the EMQX A2A profile standardised in 2026.

For cloud-only swarms, HTTP/gRPC plus a queue (NATS JetStream, Redis
Streams) is often a better fit. Runes now keeps that decision out of the
harness: `Runes::Transport` has an in-process hub (tests, embeds, offline
demos), an MQTT 3.1.1 adapter (compatibility), and a hand-rolled MQTT 5
adapter (shared subscriptions + properties). `RUNES_TRANSPORT=auto` probes.

## 0.3.0 — what changed

| Area | Before | 0.3 |
|---|---|---|
| Fabric | dispatcher owned an `MQTT::Client` loop | `Runes::Transport` adapters; handlers run on transport threads |
| Exactly-once work | claim → started → dedup maps → execution announcement | MQTT 5 `$share` group (or the in-process hub); ~250 lines deleted |
| Discovery | bespoke `runes/agents/<id>/card` | A2A card on `$a2a/v1/discovery/...` (legacy card still published) |
| Tasks | bespoke envelope | A2A task shapes + Response Topic/Correlation Data (legacy path kept) |
| Tools | in-process only | **MCP server + client** (`bin/runes-mcp`) |
| Trust | "run it on localhost" | per-agent Ed25519 identity, signed envelopes, `bin/runes-acl` |
| Tests | 202, broker-dependent, one live call | transport-level, hermetic; brokers only where the wire matters |
| Packaging | a checkout | `runes.gemspec` + optional `wasmtime` |

## Positioning by audience

- **Ruby/Rails shops**: "an agent that can safely touch our repo, with an
  audit trail and a dashboard" — the guard, WASM sandbox, journal and
  observatory are the product.
- **Edge/physical-AI teams**: "A2A agents over MQTT with real isolation" —
  discoverable by non-Ruby peers, observable from a browser.
- **Framework authors**: "MCP tools + a capability guard you can embed" —
  the MCP server and `Runes::Capabilities::Guard` work standalone.

## Open bets / honest risks

- Ruby is a small pond for agents; the cross-language wedge is A2A + MCP,
  not the harness language.
- The observatory is the most differentiated thing here and the least
  finished (no auth, sqlite-only, poll-based feed).
- Tool-result feedback for single build plans is still one-shot; missions
  compensate. A bounded plan→execute→feed-back loop is the next step.
