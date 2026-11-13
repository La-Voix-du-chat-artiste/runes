# Discovery — the observatory as a workspace: from viewer to command deck

> **Status:** discovery. A design analysis, not a plan of record.
> **Reference:** the Workday-style screenshot shared 2026-11-12 — four
> panels ("Communication", "Outils", "Flux de travail", "Mes tâches") with
> the caption *"outils et tâches dans un seul espace de travail"* — tools
> and tasks in a single workspace.
> **Companions:** `docs/OBSERVATORY_ROADMAP.md` (the standing proposal this
> extends), `runes_observer/README.md`, `STATE.md`, `docs/FLEET_DSL.md`,
> `docs/WORKFLOWS.md`.
> **Scope:** what we already have (the simpler version), what the reference
> image asks for, the gap per feature, and a phased way to close it. Every
> "today" claim names the file that proves it.

---

## TL;DR

The screenshot is not asking for a prettier dashboard. It is asking for the
observatory to stop being **eight separate pages** and become **one
workspace** with five working surfaces:

| Image panel | Workspace surface | We already have |
|---|---|---|
| Communication (news feed, likes, comments) | **Live feed** of everything on the fabric | `/` dashboard + `/packets`, polled live via `/feed` every 2.5 s (`feed_controller.js`) |
| Outils (a tool widget you act on) | **Connectors** (MQTT brokers) + **Documents** you add | `/plugins` catalog; `Runes::DocStore` in the harness, no UI; one broker via env vars only |
| Flux de travail (steps joined by `+`) | **Plan** — epic → mission → plan chain | `/runs`, `/interactions/:id` waterfall, O1.7 plan chain; planning itself is TUI-only (`/goal`, `/plan`, `/done` in `bin/runes`) |
| Mes tâches (checklist, "terminé") | **Board** — kanban of planned tasks | `/board` + `/board.mmd`, folded from packets, **read-only** |
| (the user's fifth ask) | **Agents** — everyone working together, live | `/agents`, `/topology` (declared vs observed + drift); the animated "theatre" (O2.8) is proposed, not built |

The tremendous version is therefore not new backend science — the harness
already has every primitive (content-addressed `DocStore`, the
`Runes::Transport` seam, the lossless `Runes::Kanban` `.mmd` contract, A2A
discovery, fleet extracts, the journal tail). It is **wiring those
primitives into one page where a human can act**: upload a document,
switch the MQTT connector, write a plan, drag a card on the kanban, and
watch the fleet move.

The one hard gate is already on record: **any write path needs auth**
(roadmap PR-3; the app today has none — `runes_observer/README.md` says
"a viewer, not a controller: there is no 'send prompt' button yet").

---

## 1. What we have today — the simpler version, honestly

`runes_observer/` (Rails 8.1) watches the fabric and shows it:

| Surface | Route | What it shows | Key files |
|---|---|---|---|
| Dashboard | `/` | online/ended agents, ingest health, top kinds | `app/controllers/dashboard_controller.rb`, `app/views/dashboard/index.html.erb` |
| Fleet | `/agents`, `/agents/:id` | agent cards, state, tools, per-agent feed | `app/controllers/agents_controller.rb` |
| Packets | `/packets`, `/packets/:id`, `/feed` | filterable log, bounded JSON feed polled by Stimulus | `packets_controller.rb`, `app/javascript/controllers/feed_controller.js` |
| Topology | `/topology` | declared fleet (`.fleet.rb` §8 extracts) beside the observed graph, **with the drift between them** | `topology_controller.rb`, `RUNES_OBSERVER_FLEET` |
| Runs | `/runs`, `/runs/:id` | workflow runs + steps as first-class objects (O1.1) | `runs_controller.rb`, models `workflow_run.rb` / `workflow_step.rb` |
| Interactions | `/interactions/:id` | one request/lease waterfall; O1.7 plan chain | `interactions_controller.rb` |
| Board | `/board`, `/board.mmd` | Planned / Working / Done folded from packets, Mermaid kanban + HTML fallback | `board_controller.rb`, `app/services/board/kanban.rb` |
| Security | `/security` | signature states, impersonation, guard refusals | `security_controller.rb` |
| Plugins | `/plugins` | rune/plugin catalog from the registry (O1.6) | `plugins_controller.rb` |
| Alerts | `/alerts` | abnormality list + ack (O1.5) | `alerts_controller.rb` |

Ingest: one process (`bin/rails runes:ingest` / `runes:ingest`) subscribed
through `Runes::Transport` to `runes/#` and `$a2a/#`, recording into
`agents`, `packets`, `ingest_statuses` (singleton), plus the journal tail
(`log/journal.jsonl`) as a second source. Broker is configured **only** by
env: `RUNES_MQTT_HOST`, `RUNES_MQTT_PORT`, `RUNES_TRANSPORT`
(`auto | mqtt5 | mqtt311 | inproc`).

**What is missing, mapped to the five asks:**

1. **Documents** — `Runes::DocStore` exists in the harness
   (`lib/runes/doc_store.rb`: content-addressed `<root>/ab/cd/<sha256>.<ext>`,
   extension whitelist, path-escape guard, used by
   `examples/prospect_pipeline.rb`). The observer has **no document
   surface at all** — nothing to upload, list, preview or link to a packet.
2. **MQTT connectors** — exactly one broker, from env vars, fixed at ingest
   start. No UI to add, test, or switch connectors. (`IngestStatus` is a
   singleton precisely because there is one.)
3. **Plan** — planning lives only in the TUI: `/goal` → `/done` writes
   `docs/epics/*.md`, `/plan` writes `docs/missions/*.json` under the
   workspace root (`Runes::Core::Settings.default_root`, `bin/runes:115,152,156`),
   `/build` executes a mission. The observer *sees the resulting packets*
   but cannot start, list, or compose a plan.
4. **Kanban of planned tasks** — `/board` exists but is **derived and
   read-only**: `Board::Kanban` folds packets into columns. The harness's
   own `Runes::Kanban` (`lib/runes/kanban.rb`, `bin/runes-kanban`) is a
   lossless read/write implementation of the `.mmd` contract that workflows
   and external harnesses already share — the observer does not use it.
5. **All agents working together** — `/agents` + `/topology` show *who*
   exists and the declared/observed drift, but there is no live "everyone
   at once" view. O2.8 (swarm theatre: force-graph + message particles from
   `/feed`, kiosk `/wall`) is proposed in the roadmap, **not built**.

---

## 2. The target: one workspace page

A single `/workspace` page (the existing routes stay as deep links) laid out
like the reference — panels, not pages:

```
┌──────────────────────────────────────────────────────────────┐
│ RUNES OBSERVATORY   Fleet Board Packets Topology Runs …  [●] │  nav (unchanged)
├──────────────┬─────────────────────────────┬─────────────────┤
│ Communication│  Flux de travail (Plan)     │  Mes tâches     │
│ live feed    │  epic → mission → plan chain│  Board kanban   │
│ (packets,    │  + steps joined by +        │  (drag cards)   │
│  docs, plans)│                             │                 │
├──────────────┴─────────────────────────────┴─────────────────┤
│ Outils: Connectors (MQTT) · Documents (upload/preview)       │
│ Agents: theatre — all agents + message particles, live        │
└──────────────────────────────────────────────────────────────┘
```

The grammar borrowed from the image: a **feed** on one side, **tools you
act on** (connectors, documents) in a rail, a **workflow** rendered as
steps joined by `+` (that is exactly the O1.7 plan chain: prompt → plan →
tool calls → evidence → verdict), and a **task list** with checkboxes (the
`.mmd` `- [ ]` / `- [x]` grammar). What we do *not* borrow is the HR
domain — the panels are ours: fabric traffic, brokers, documents, missions,
agents.

---

## 3. Feature-by-feature: today → target

### 3.1 Documents — add, list, preview, link

- **Today:** `Runes::DocStore` in the harness; nothing in the observer.
- **Design:** a `documents` table (`sha` PK, `ext`, `bytes`, `name`,
  `uploaded_by`, `created_at`, `first_packet_id` nullable) + the store
  itself rooted at `RUNES_OBSERVER_DOCSTORE` (default
  `<harness>/docs/store`). Upload endpoint (multipart, one file) →
  `DocStore.put` → row. List/preview page: inline render for
  `txt/md/json/csv/html` (escaped, CSP `default-src 'none'` on the preview
  frame), download for `pdf`. `GET /documents/:sha.:ext` serves **only**
  after re-validating `sha =~ /\A[0-9a-f]{64}\z/` and `ext` against
  `DocStore::EXTS` — the store's own guard is the model, the controller
  re-checks rather than trusting the DB. `X-Content-Type-Options: nosniff`.
- **Link to the fabric:** when a packet payload contains a 64-hex sha that
  exists in `documents`, the packet page renders a chip linking to the doc
  (the join key already exists in spirit: `correlation_id` is indexed for
  the same reason).
- **Publish on the fabric:** on upload, publish a small
  `runes/docs/added` packet (`{sha, ext, bytes, name}`) so the feed, the
  board and other agents see it — documents become first-class fabric
  citizens, not just files.
- **Acceptance:** upload a `.md`, it appears in `/documents`, its sha chip
  shows on the packet that referenced it, `GET /documents/<sha>.md`
  returns the bytes, and a `../` or wrong-ext request is refused.
- **Risks:** serving user content (traversal, sniffing, stored XSS via
  `html`) — mitigated by the double validation + nosniff + sandboxed
  preview; 256 KiB payload truncation already applies to packets, set a
  separate doc size cap (e.g. 5 MiB).

### 3.2 MQTT connectors — named, testable, switchable

- **Today:** one broker from `RUNES_MQTT_HOST/PORT`, transport from
  `RUNES_TRANSPORT`; `IngestStatus` singleton; ingest is a separate process
  started with env.
- **Design:** a `connectors` table (`name` unique, `host`, `port`,
  `transport`, `tls`, `client_id`, `username`, `password` encrypted or
  env-referenced, `active` boolean, `last_probe_at`, `last_probe_state`).
  `/connectors` lists them with a **Test** button (opens a short-lived
  `Runes::Transport.build` connection, reads retained `$a2a/v1/discovery/#`
  for N seconds, reports agent count — a probe, not an ingest) and an
  **Activate** button. Activate flips `active`, then signals the ingest
  process (a `connector_epoch` row the ingest polls, or a `runes/observer/control`
  topic — the fabric already has the pattern) to rebuild `FabricIngest`
  against the new connector; the layered reconnect/rebuild logic from O0.1
  is reused, not rewritten.
- **Honest constraint (roadmap §6):** *no multi-broker federation* — one
  active connector per observer keeps `IngestStatus` and the topic grammar
  honest. Secondary connectors are **probe-only** until that decision is
  revisited.
- **Acceptance:** add a second broker profile, Test shows the retained
  agent cards, Activate switches the ingest pill to the new host:port and
  packets flow from it; deactivating back restores the first.
- **Risks:** credentials in the DB (use Rails credentials / env refs, never
  plaintext columns); a control topic on the fabric is itself a write path →
  behind auth, and ACL-restricted to the observer's broker user
  (`bin/runes-acl` already renders per-role ACLs).

### 3.3 Plan — from the UI, not just the TUI

- **Today:** `/goal` → `/done` → `docs/epics/E-*.md`; `/plan` →
  `docs/missions/*.json`; `/build` runs a mission — all in `bin/runes`,
  all on disk under the workspace root. The observer sees the packets but
  cannot start anything.
- **Design:** a `/plan` page with two halves. **Read:** list epics and
  missions from `RUNES_OBSERVER_WORKSPACE` (default the harness root,
  same `default_root` the TUI uses), each mission showing its todos and
  its O1.7 plan chain (prompt → plan → tool calls → verdict) joined from
  `packets`. **Write (behind auth):** a composer — "New epic" textarea
  writes `docs/epics/E-<n>.md` through the same sanitize path the TUI uses;
  "Plan this epic" publishes the planning prompt to `runes/prompts/<agent>`
  (the exact topic the TUI publishes to) so the *existing* planner agents
  do the work — the observer stays a participant, not a second planner.
- **Acceptance:** with auth on, create an epic from `/plan`, hit "plan",
  and within seconds a mission file appears, `/board` gains Planned cards,
  and `/interactions` shows the chain.
- **Risks:** this is the first **remote-execution** feature — PR-3 says
  auth is not optional. Minimal gate: `RUNES_OBSERVER_TOKEN` (bearer or
  HTTP Basic) checked in `ApplicationController` for all non-GET routes;
  read-only pages stay open. Publishing to the fabric must go through the
  guard like any agent (`runes/guard/denied` will show it if refused).

### 3.4 Kanban of planned tasks — editable, shared with the agents

- **Today:** `/board` folds packets into Planned/Working/Done
  (`app/services/board/kanban.rb`), renders Mermaid + HTML, exports
  `/board.mmd`. Read-only; not tied to a mission file.
- **Design:** make the board **file-backed per mission**:
  `docs/missions/<id>.mmd` written and read through the harness's
  `Runes::Kanban` (`lib/runes/kanban.rb`) — the same lossless
  render/parse/validate contract `pipeline_prospect`'s external harness
  edits with `$EDITOR`. The UI board becomes a view over that file:
  drag a card between columns → `POST /board/:mission/cards/:n/move` →
  server parses the `.mmd`, mutates, re-renders, writes the file, appends a
  journal line, and publishes a `runes/board/moved` packet so every
  observer and agent sees the move. `/board.mmd` keeps serving the same
  bytes the page renders. The packet-folded view stays as the
  "fleet-wide" board; the mission board is the "planned tasks" board.
- **Conflict story:** human and agent can edit the same file —
  last-write-wins on the file, but every move is journaled with a
  deterministic id (the fleet engine's `RequestLedger` pattern), so the
  interaction view can show who moved what when.
- **Acceptance:** drag a card in the UI → the `.mmd` on disk changes →
  `/board.mmd` reflects it → `Runes::Kanban.parse` round-trips it →
  `bin/runes-kanban` shows the same board on the CLI.
- **Risks:** concurrent writes (file lock + atomic rename); title
  sanitisation is already handled by `Runes::Kanban` (TITLE_LIMIT, no
  forged checkboxes/newlines).

### 3.5 All agents working together — the theatre

- **Today:** `/agents` list, `/agents/:id` detail, `/topology` declared vs
  observed + drift badges, `/interactions/:id` waterfall.
- **Design:** O2.8 as specced — a `/theatre` canvas: force-directed graph
  of agents (nodes from `agents` + the declared fleet), edges from the
  fleet's `route`s, and **message particles** animated along edges from the
  existing `/feed` (no new backend; the feed already carries topic +
  agent_id + request_id). Plus a per-agent swimlane strip under the graph
  (what each agent did in the last N minutes) and a `/wall` kiosk mode
  (auto-refreshing, no nav) for a screen on the wall. Time-travel scrubber
  over the stored packets when rollups land (O0.4).
- **Acceptance:** with `bin/rails runes:demo` seeded, particles flow along
  the declared routes, undeclared agents show the drift badge, and clicking
  a node deep-links to `/agents/:id`.
- **Risks:** it is chrome — the roadmap says build it last; keep it honest
  (particles are real packets, not decoration).

---

## 4. Proposed shape (routes, models, services)

| Layer | New pieces |
|---|---|
| Routes | `get /workspace` (the shell); `resources :connectors` (+ `post :test`, `post :activate`); `resources :documents` (+ `get /documents/:sha.:ext`); `get /plan`, `post /plan/epics`, `post /plan/:epic/plan`; `post /board/:mission/cards/:n/move`; `get /theatre`, `get /wall`; extend `/feed` consumers for `runes/docs/added`, `runes/board/moved`, `runes/observer/control` kinds |
| Models | `Connector`, `Document`; (missions/epics are read from the workspace docs dir, not duplicated into the DB — the file is the source of truth, same as the TUI) |
| Services | `ConnectorManager` (build/probe/activate via `Runes::Transport`, signals ingest), `DocStore` serving wrapper (re-validates sha+ext), `MissionStore` (reads `docs/epics`, `docs/missions`, parses `.mmd` via `Runes::Kanban`), `Board::Kanban` extended from packet-folded to file-backed, `Theatre::Graph` (agents + routes + recent packet edges) |
| JS (Stimulus) | `workspace_controller` (panel layout), `connectors_controller`, `documents_controller` (upload + preview), `plan_controller` (composer), `board_controller` (add drag-and-drop to the existing one), `theatre_controller` (canvas + particles from `/feed`) |
| Auth | `RUNES_OBSERVER_TOKEN`; all non-GET routes require it when set (PR-3). First write features ship only behind it |

Ingest changes are deliberately small: new topic kinds in the classifier
(`runes/docs/*`, `runes/board/*`, `runes/observer/*`), a polled
`connector_epoch` check to rebuild on activation, and that is it — the
transport seam does the rest.

---

## 5. Phasing

1. **Slice 1 — the shell (days):** `/workspace` page embedding the existing
   panels (feed, board, topology, runs) in the reference layout. Zero new
   backend. Acceptance: one URL shows communication + board + agents
   together; existing routes untouched.
2. **Slice 2 — read-side tools (week):** documents upload/list/preview +
   `runes/docs/added`; connectors CRUD + Test + Activate; `/plan` read view
   (epics, missions, plan chains); `/theatre` v1 (graph + particles from
   `/feed`). Acceptance: each surface works against a demo-seeded fabric.
3. **Slice 3 — write-side, behind auth (week+):** token auth on non-GET;
   plan composer (epic write + publish-to-`runes/prompts`); board
   drag-and-drop writing the mission `.mmd`; connector switching live.
   Acceptance: the full loop from the UI — add a doc, plan an epic, watch
   the kanban move, see the agents work.

---

## 6. Risks and honest notes

- **Auth before any write** (PR-3, roadmap §6). Slices 1–2 are read-only
  and safe without it; slice 3 must not ship without the token gate, and
  the control topic must be ACL-restricted to the observer's broker user.
- **One active broker.** Multi-broker federation stays deliberately out
  (roadmap §6); connectors are profiles with probe-only secondaries.
- **Serving documents is a security surface** — double validation of
  sha+ext, `nosniff`, sandboxed preview, size cap. `DocStore` already
  refuses path escapes on write; the controller must not trust the DB row.
- **Kanban write conflicts** (human vs agent on the same `.mmd`) —
  last-write-wins + journaled, deterministic move ids; the interaction
  view is the audit trail.
- **The reference is an HR SaaS screenshot.** We borrow the panel grammar
  (feed / tools / workflow / tasks in one space), not the domain, and not
  the SaaS — the README's thesis stands: the alternative to a SaaS is a
  file.
- **No LLM summarisation of the feed** (roadmap §6) — the Communication
  panel stays raw packets with filters, which is the trustworthy version.

---

## 7. Open questions

1. **Auth model:** simple `RUNES_OBSERVER_TOKEN` bearer, or ride the broker
   ACL / mTLS the fleet already has (`bin/runes-acl`)? Token first, mTLS
   later.
2. **One page or panels-as-pages:** is `/workspace` a real single page, or
   a dashboard that embeds the existing routes in iframes/panels? (Embed
   first — no route changes — then merge.)
3. **Mission store:** read `docs/epics` + `docs/missions` from the harness
   root directly (file = source of truth, like the TUI), or mirror into the
   observer DB for querying? File first; mirror only if queries hurt.
4. **Theatre scope:** particles from `/feed` only (honest, cheap), or also
   replay from stored packets for the time-travel scrubber (O0.4
   rollups)? Feed first.
