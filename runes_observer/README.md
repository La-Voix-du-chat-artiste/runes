# Runes Observatory

A **Rails 8.1 / Ruby 4** app that watches the Runes MQTT fabric and shows
what the fleet is doing:

- **Fleet** — which agents are running, which are stale, and which have
  ended (Last Will), with their tools, workspace and last-seen age.
- **Live packet feed** — every PUBLISH on `runes/#`, newest first,
  expandable to the raw JSON payload (a bounded summary inline; the full
  body at `/packets/:id`).
- **Agent view** — click an agent for its card, its **interactions**
  (grouped by `request_id`, with the whole prompt → progress → response →
  journal timeline, paginated), and its recent packet history.
- **Packet log** — filter by agent, kind, request, topic and payload text,
  or by recency.
- **Interaction view** — one screen per request.
- **Ingest health** — is anything actually watching the bus?

The observer is **read-only**: it subscribes and records, and never
publishes to the fabric.

## Quick start

```bash
cd runes_observer
bundle install
bin/rails db:prepare

# 1) a broker — mosquitto, or the Runes embedded one
mosquitto -p 1883 &
#   or: (cd .. && bundle exec ruby demo/broker.rb 1883)

# 2) the ingest process (long-running)
bin/runes-ingest                  # RUNES_TRANSPORT=auto: mqtt5 → mqtt311 → inproc

# 3) the web UI
bin/rails server -p 3100
# → http://127.0.0.1:3100
```

`RUNES_TRANSPORT` chooses the ingest's adapter. `mqtt5` (the default choice on
a modern broker) and `inproc` need no client gem at all; `mqtt311` is the one
adapter that needs `gem "mqtt"` in this app's Gemfile — the ingest says so
explicitly and keeps retrying rather than dying if it is missing.

No broker handy? Either watch only this process — `RUNES_TRANSPORT=inproc
bin/runes-ingest` — or seed a realistic session through the same code path the
live ingest uses and browse it immediately:

```bash
bin/rails runes:demo        # 2 agents (one running, one ended), 35 packets
bin/rails server -p 3100
```

Publish a live interaction at any time: a card, status, prompt envelope,
progress, response, journal entry and a tool RPC to `127.0.0.1:1883` are
all classified and stored.

## How it works

```
   the fabric ──runes/#──▶ FabricIngest ──▶ PacketClassifier ──▶ PacketRecorder ──▶ SQLite
(mosquitto / embedded /       (bin/runes-ingest)  (topic → kind/agent/request)      │
 in-process hub)                                                                     ▼
                      browser ◀── Stimulus /feed poller ◀── PacketsController ──▶ views
```

- `FabricIngest` subscribes to `runes/#` and `$a2a/#` **through
  `Runes::Transport`** — the same seam the fleet publishes through — so the
  observer sees what the transport sees: MQTT 5 `correlation_id`,
  `response_topic` and `user_properties`, plus `qos` and `retain`.
  `RUNES_TRANSPORT` picks the adapter (`mqtt5`, `mqtt311`, `inproc`; default
  `auto` = mqtt5 → mqtt311 → inproc) and `inproc` runs the whole observatory
  with no broker at all, which is how its own tests drive it. It reconnects
  with backoff — a drop shorter than `DISCONNECT_GRACE_S` is the adapter's own
  business, mirrored from its `on_health` — and writes its health into
  `ingest_statuses` so the UI can show whether, and via what, the bus is being
  watched.
- `PacketClassifier` maps a topic to a `kind` and extracts
  `agent_id` / `request_id` / `event` / `tool` from the topic and the JSON
  payload. It mirrors the Runes topic map; unknown topics are stored as
  `other` rather than dropped. The Phase 16 deletion of the claim/lease
  protocol is mirrored here: there is no claim/started/session vocabulary.
- `PacketRecorder` is the single write path — live ingest and the demo
  seeder both go through it, so the UI can never show rows the recorder
  would not have produced. It also updates the agent row (card metadata,
  online/offline, last seen, packet count), repairs non-UTF-8 payloads to
  valid UTF-8 (flagging the row `scrubbed`), backfills a request's
  `agent_id` when the executor becomes known (the journal entry's `agent`,
  or a delegation envelope's `from`), and prunes on a schedule.
  The ingest drops a single message it cannot store — counted in
  `ingest_statuses.packets_dropped` — instead of tearing down the
  connection.
- The web process **polls** `GET /feed?after_id=…` (JSON) from a small
  Stimulus controller and prepends rows rendered by the same partial as the
  first page. Every list view serves only a bounded payload summary
  (2 KiB); the full body lives at `/packets/:id`. SQLite WAL lets the
  ingest write while the UI reads; no message broker is needed between the
  two Rails processes.

## Data model

| Table | Purpose |
|---|---|
| `agents` | one row per observed agent: card metadata, `state` (online/offline/unknown), first/last seen, packet count |
| `packets` | every observed PUBLISH: topic, payload (≤256 KiB), classified `kind`, `agent_id`, `request_id`, `event`, `tool`, timestamps |
| `ingest_statuses` | singleton row: connected?, broker, last message, packets this run, packets dropped, last error |

## A2A topics

The harness also speaks the A2A-over-MQTT profile (`lib/runes/a2a.rb`), and
the observer classifies those topics into the same feed and agent views:

| Topic | Kind | What the observer shows |
|---|---|---|
| `$a2a/v1/discovery/<org>/<unit>/<agent_id>` | `a2a_card` | The retained Agent Card for `<agent_id>`. Its Runes facts (`kind`, `workspace`, `tools`) live under `x-runes`; the classifier lifts them onto the top level, so the fleet row is populated exactly like a legacy card. Presence (`online`/`offline`/`lwt`) rides on the MQTT 5 `a2a-status` user property, so a retained card never flips the agent's state. |
| `$a2a/v1/tasks/<org>/<unit>/<agent_id>` | `a2a_task` | An addressed task for `<agent_id>`: it appears in the packet feed and that agent's packet history, with `request_id` taken from the payload's `request_id`/`taskId` when present. |

MQTT wildcards never match `$`-prefixed topics, so the ingest must subscribe
to `$a2a/#` in addition to `runes/#` for these packets to be seen.

## Rake tasks

```bash
bin/rails runes:ingest               # run the subscriber in the foreground
bin/rails runes:demo                 # seed a demo session (RUNES_OBSERVER_RESET=0 to append)
bin/rails runes:stats                # agents/packets/kinds + ingest health
bin/rails runes:prune[7]             # drop packets older than 7 days, then cap the table
bin/rails runes:reset                # delete every observed packet and agent
```

## Configuration

| Env var | Default | Purpose |
|---|---|---|
| `RUNES_MQTT_HOST` | `127.0.0.1` | Broker host |
| `RUNES_MQTT_PORT` | `1883` | Broker port |
| `RUNES_OBSERVER_RETENTION_DAYS` | `7` | Prune packets older than this |
| `RUNES_OBSERVER_MAX_PACKETS` | `200000` | Hard cap on stored packets; `0` or less (or non-numeric) means no cap |
| `RAILS_MAX_THREADS` | `5` | Puma/DB pool size |

## Tests

```bash
bin/rails test     # 89 runs, 454 assertions
```

Covers the topic classifier (every Runes topic shape, including the A2A
discovery/task topics and their fallback to `other`, and the deleted
claim/lease grammar falling through to `other`), the recorder's agent
bookkeeping, UTF-8 repair of non-UTF-8 payloads, journal backfill
attribution, retained-replay dedupe and retention, the per-message ingest
isolation and its survival of a locked database, the singleton ingest
status (including the dead-ingest state), the demo seeder, all four
controllers (HTML, the bounded JSON feed and the full-payload page) and an
integration walk from recorded packet → dashboard → agent → interaction →
filtered log.

## Notes and limits

- Payloads larger than 256 KiB are truncated for storage (the real size is
  kept and the row is flagged).
- The classifier is a mirror of the Runes topic map; a new topic shape shows
  up as `other` until it is added.
- `json` is pinned to `~> 2.21`: the `json 3.0.0` gem on this machine
  changed `JSON.parse`'s signature, which breaks Rails 8.1's
  ActiveSupport::JSON decoding of flash/cookie metadata.
- The app is a viewer, not a controller: there is no "send prompt" button
  yet (that would be the natural next step).
