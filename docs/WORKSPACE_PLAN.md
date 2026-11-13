# Plan — building the workspace (implements `docs/WORKSPACE_DISCOVERY.md`)

> **Status:** plan of record for the next phase. Companion discovery:
> [`WORKSPACE_DISCOVERY.md`](WORKSPACE_DISCOVERY.md). Roadmap context:
> [`OBSERVATORY_ROADMAP.md`](OBSERVATORY_ROADMAP.md).
> **Platform:** Ruby **4.0.4** (rvm, already pinned in `.ruby-version` at the
> repo root and in `runes_observer/`) and the latest Rails on the 8.1 line —
> **8.1.4.1** on rubygems today (no 8.2 yet). The observer currently runs
> 8.1.3.1, so step 0 is a small bump, not a rewrite.
> **App:** `runes_observer/` (Rails 8.1, SQLite, Propshaft, importmap +
> Stimulus + Turbo, no ActionCable — the `/feed` poller stays the live
> channel).

---

## Step 0 — platform bump, green baseline (do first, alone)

1. `rvm use 4.0.4` (already the default per `.ruby-version`); confirm
   `ruby -v` → `ruby 4.0.4`.
2. `runes_observer/Gemfile`:
   - `gem "rails", "~> 8.1.4", ">= 8.1.4.1"` (was `~> 8.1.3, >= 8.1.3.1`)
   - `gem "sqlite3", ">= 2.10"` (latest 2.10.2)
   - `gem "puma", ">= 8.0.3"` (latest 8.0.3)
   - **Keep** `gem "json", "~> 2.21"` and its comment: json 3.x makes
     `JSON.parse` keyword-only and breaks Rails 8.1's
     `ActiveSupport::JSON.decode` of flash/cookie metadata. Re-evaluate only
     when Rails 8.2 lands.
3. `cd runes_observer && bundle update rails sqlite3 puma && bin/rails zeitwerk:check`
4. Baseline must be green before any feature work:
   `bin/rails test` → **231 runs, 1 148 assertions** (current count; the new
   tests below add to it). If anything breaks on 8.1.4.1, fix it here, in its
   own commit, before touching features.
5. Record the bump in `DEVELOPMENT_LOG.md` (new phase entry) and the
   observer README's status line.

---

## Slice 1 — the workspace shell (read-only, no new backend)

Goal: one URL that shows communication + board + agents together, in the
panel layout of the reference image. Existing routes stay as deep links.

| # | Task | Files |
|---|---|---|
| 1.1 | Route + nav: `get "workspace", to: "workspace#index"`, make it `root`; add "Workspace" as the first nav link | `config/routes.rb`, `app/views/layouts/application.html.erb` |
| 1.2 | `WorkspaceController#index` gathering: online agents, last N packets (reuse the packets partial), board summary (`Board::Kanban` small window), topology drift count (`FleetTopology`), recent runs, ingest status | `app/controllers/workspace_controller.rb` |
| 1.3 | View: CSS-grid panel layout — Communication (live feed via the existing `feed_controller`), Board (kanban columns partial), Agents (fleet partial + drift badge), Runs strip | `app/views/workspace/index.html.erb`, reuse `app/views/agents/_fleet.html.erb`, board column partials, `app/assets/stylesheets/application.css` (add a `workspace` grid section) |
| 1.4 | Stimulus `workspace_controller.js` only if panels need behavior (e.g. collapsible panels); otherwise pure CSS | `app/javascript/controllers/workspace_controller.js`, register in `controllers/index.js` |
| 1.5 | Tests: controller test (renders all panels with demo seed), integration walk dashboard→workspace | `test/controllers/workspace_controller_test.rb`, `test/integration/` |

**Acceptance:** with `bin/rails runes:demo` seeded, `/` shows feed + board +
agents + runs in one page; every existing route still works; suite green.

---

## Slice 2 — read-side tools

### 2A. Documents (upload, list, preview, link, publish)

| # | Task | Files |
|---|---|---|
| 2A.1 | Migration `create_documents`: `sha` (string, unique index), `ext`, `bytes` (int), `name`, `uploaded_by`, `first_packet_id` (nullable), timestamps | `db/migrate/…_create_documents.rb` |
| 2A.2 | Model `Document` — validates `sha =~ /\A[0-9a-f]{64}\z/`, `ext` in the harness whitelist; `PREVIEWABLE = %w[txt md json csv html]` | `app/models/document.rb` |
| 2A.3 | Service `DocStoreService` — wraps the harness `Runes::DocStore` (require via the load path from `config/initializers/runes_transport.rb`), root = `RUNES_OBSERVER_DOCSTORE` (default `<harness>/docs/store`); `put(file_or_string, name:)` → store + row; `path_for(sha, ext)` **re-validates sha+ext before returning a path** | `app/services/doc_store_service.rb` |
| 2A.4 | Routes: `resources :documents, only: %i[index create]`; `get "/documents/:sha.:ext", to: "documents#serve", format: false` (same trick as `board.mmd`) | `config/routes.rb` |
| 2A.5 | `DocumentsController`: `index` (list + upload form, multipart, one file, size cap 5 MiB), `create` (→ `DocStoreService.put`, then publish `runes/docs/added` `{sha, ext, bytes, name}` via `FabricPublisher`, redirect), `serve` (validate sha+ext again, `send_file` with `disposition: :inline` for previewable / `:attachment` for pdf, `X-Content-Type-Options: nosniff`, content type by ext; preview of `html` rendered in a sandboxed iframe with CSP `default-src 'none'`) | `app/controllers/documents_controller.rb`, `app/views/documents/index.html.erb` |
| 2A.6 | Classifier: add kind `doc_added` for `runes/docs/added` (regex + `KINDS` + unit tests) | `app/services/packet_classifier.rb`, `test/services/packet_classifier_test.rb` |
| 2A.7 | Packet page: if payload contains a 64-hex sha present in `documents`, render a chip linking to `/documents/<sha>.<ext>` | `app/views/packets/show.html.erb` (+ helper) |
| 2A.8 | Tests: model validation; service round-trip (put → path_for → read); controller upload + serve; **refusals**: `../` sha, bad ext, oversize; classifier kind | `test/models/document_test.rb`, `test/services/doc_store_service_test.rb`, `test/controllers/documents_controller_test.rb` |

### 2B. MQTT connectors (named profiles, probe, activate)

| # | Task | Files |
|---|---|---|
| 2B.1 | Migration `create_connectors`: `name` (unique), `host`, `port`, `transport` (default `auto`), `tls` (bool), `client_id`, `username`, `password_env` (name of env var holding the secret — **never a plaintext password column**), `active` (bool), `last_probe_at`, `last_probe_state`, `last_probe_detail`, timestamps. Plus migration adding `connector_epoch` (int, default 0) to `ingest_statuses` | `db/migrate/…` |
| 2B.2 | Model `Connector` — validations (host presence, port 1..65535, transport in `%w[auto mqtt5 mqtt311 inproc]`); at most one `active` row (enforced in `ConnectorManager.activate!`, not a DB constraint, so the flip is transactional) | `app/models/connector.rb` |
| 2B.3 | Service `ConnectorManager`: `probe(connector)` builds `Runes::Transport.build(host:, port:, transport:, …)` with a short timeout, subscribes `$a2a/v1/discovery/#`, collects retained Agent Cards for `RUNES_CONNECTOR_PROBE_SECONDS` (default 5), disconnects, writes `last_probe_*`; `activate!(connector)` — transaction: unset others, set active, `IngestStatus.current.update!(connector_epoch: +1)`; `current_settings` — first active connector, else env fallback (`RUNES_MQTT_HOST/PORT/TRANSPORT`) so a fresh install with zero rows behaves exactly as today | `app/services/connector_manager.rb` |
| 2B.4 | Ingest rebuild: `FabricIngest`'s run loop checks `IngestStatus.current.connector_epoch` each iteration (and on a short timer thread); on change, tear down and rebuild the transport from `ConnectorManager.current_settings` — reuses the existing layered backoff, no new reconnect logic | `app/services/fabric_ingest.rb` |
| 2B.5 | Routes + controller + views: `resources :connectors, only: %i[index new create edit update destroy]`; `post "connectors/:id/test"`, `post "connectors/:id/activate"`; index shows probe state + active badge + the ingest pill target | `config/routes.rb`, `app/controllers/connectors_controller.rb`, `app/views/connectors/` |
| 2B.6 | Tests: model; `probe` against an inproc hub seeded with a retained card (same pattern as the existing transport-backed ingest tests); `activate!` flips active + bumps epoch; ingest rebuilds on epoch change; env fallback with empty table | `test/models/connector_test.rb`, `test/services/connector_manager_test.rb`, `test/services/fabric_ingest_test.rb` (extend) |

### 2C. Plan — read view (epics, missions, plan chain)

| # | Task | Files |
|---|---|---|
| 2C.1 | Service `MissionStore` — workspace root = `RUNES_OBSERVER_WORKSPACE` (default: harness `Runes::Core::Settings.default_root`, the same root the TUI uses); lists `docs/epics/*.md` and `docs/missions/*.json` (+ `.mmd` parsed through the harness `Runes::Kanban` — lossless render/parse); the **file is the source of truth**, nothing is mirrored into the DB | `app/services/mission_store.rb` |
| 2C.2 | Routes + controller + views: `get "plan", to: "plan#index"` (epics + missions with todo checkboxes from the `.mmd`), `get "plan/missions/:id", to: "plan#show"` — mission detail joining the existing `PlanChain` service (prompt → plan → tool calls → verdict) from `packets` by request_id | `config/routes.rb`, `app/controllers/plan_controller.rb`, `app/views/plan/` |
| 2C.3 | Tests: service against a tmp workspace fixture (epic md, mission json, mmd round-trip via `Runes::Kanban.parse`); controller renders both pages | `test/services/mission_store_test.rb`, `test/controllers/plan_controller_test.rb` |

### 2D. Theatre — all agents working together, live

| # | Task | Files |
|---|---|---|
| 2D.1 | Service `Theatre::Graph` — nodes: `Agent` rows (online/ended) + declared fleet agents from `FleetDeclaration`; edges: fleet `route`s + observed edges from `packets` in the last N minutes (agent→agent via request/response correlation); drift flags for undeclared agents | `app/services/theatre/graph.rb` |
| 2D.2 | Routes + controller: `get "theatre", to: "theatre#show"`, `get "wall", to: "theatre#wall"` (kiosk: no nav, meta refresh) | `config/routes.rb`, `app/controllers/theatre_controller.rb`, `app/views/theatre/` |
| 2D.3 | Stimulus `theatre_controller.js` — canvas force-graph (hand-rolled ~100 lines, no new dependency; Mermaid is vendored but is not a graph lib), particles spawned from `/feed` events mapped onto edges, node click → `/agents/:id`; swimlane strip of per-agent last-N-minutes activity | `app/javascript/controllers/theatre_controller.js`, register in `index.js` |
| 2D.4 | Tests: graph service (nodes/edges/drift from demo seed); controller; integration: seed → `/theatre` renders graph JSON + page | `test/services/theatre_graph_test.rb`, `test/controllers/theatre_controller_test.rb` |

---

## Slice 3 — write-side, behind auth (PR-3 gate)

| # | Task | Files |
|---|---|---|
| 3.1 | **Auth:** `RUNES_OBSERVER_TOKEN` env. In `ApplicationController`: `before_action :require_observer_token` that no-ops for GET/HEAD and when the env is unset, else requires `Authorization: Bearer <token>` (or HTTP Basic password = token); 401 otherwise. All slice-3 routes are non-GET, so the gate covers exactly the write surface | `app/controllers/application_controller.rb`, `config/initializers/` (env read) |
| 3.2 | `FabricPublisher` service — lazy, mutex-guarded `Runes::Transport` connection in the web process for one-shot publishes (publish envelope → short linger → reuse; drop on error); envelope shape copied from the TUI's `publish_envelope` (`request_id`, `mode`, `prompt`, …) to `runes/prompts` | `app/services/fabric_publisher.rb` |
| 3.3 | Plan composer: `post "plan/epics"` (textarea → same sanitize path as `bin/runes` → write `docs/epics/E-<n>.md` under the workspace root, atomic tmp+rename); `post "plan/epics/:id/plan"` → `FabricPublisher` publishes the `mode: "plan"` envelope with `epic_path`, exactly like the TUI's `/plan` | `app/controllers/plan_controller.rb` (extend), `app/views/plan/` (composer form) |
| 3.4 | Board editing: mission board is file-backed at `docs/missions/<id>.mmd`. `post "board/missions/:id/cards/:index/move"` with `to:` column → `Runes::Kanban.parse` → mutate → re-render → atomic write → journal line (`log/journal.jsonl` append, same format `JournalTail` reads) → publish `runes/board/moved` `{mission:, index:, from:, to:}`. `/board.mmd` keeps serving the same bytes the page renders | `app/controllers/board_controller.rb` (extend), `app/services/mission_store.rb` (mmd read/write), classifier kind `board_moved` |
| 3.5 | Drag-and-drop: extend `kanban_controller.js` with HTML5 drag events on cards; on drop, `fetch` POST with the CSRF token; optimistic move + revert on failure | `app/javascript/controllers/kanban_controller.js` |
| 3.6 | Classifier: add `board_moved` (`runes/board/moved`) and `observer_control` (`runes/observer/control`) kinds + tests | `app/services/packet_classifier.rb`, tests |
| 3.7 | Tests: 401 without token on POST, 200 with; epic write sanitization (newline/`..` in title refused); move endpoint round-trips through `Runes::Kanban.parse` and appends a journal line; publisher publishes to an inproc hub | `test/controllers/*`, `test/services/*`, `test/integration/workspace_write_flow_test.rb` |

---

## Cross-cutting

- **Demo seeder:** extend `DemoFabric` so `bin/rails runes:demo` also seeds
  one connector row (inproc), two documents via `DocStoreService`, and a
  mission `.mmd` in a tmp workspace (`RUNES_OBSERVER_WORKSPACE` in test) —
  `/workspace` must look alive with zero manual setup.
- **Feed:** new kinds flow through `/feed` automatically; add filter chips on
  `/packets` for `doc_added` / `board_moved`.
- **Docs/bookkeeping (repo convention):** update `runes_observer/README.md`
  (features + the env-var table: `RUNES_OBSERVER_TOKEN`,
  `RUNES_OBSERVER_DOCSTORE`, `RUNES_OBSERVER_WORKSPACE`,
  `RUNES_CONNECTOR_PROBE_SECONDS`), `STATE.md` status line,
  `DEVELOPMENT_LOG.md` phase entries, and mark the discovery's status.
- **Harness suite untouched:** the observer mirrors the topic grammar, so
  classifier changes are additive (`KINDS` grows); run the harness
  `test/transport_test.rb` once after the classifier change to confirm the
  cross-check still passes.

## Definition of done (the full loop, from the UI)

With `RUNES_TRANSPORT=inproc` and `bin/rails runes:demo` seeded:

1. `/` (workspace) shows feed + board + agents + runs in one page.
2. Upload a document → it appears in `/documents`, a `doc_added` packet
   appears in the feed, and its sha chip links from the referencing packet.
3. Add a connector, **Test** shows retained agent cards, **Activate** flips
   the ingest pill to the new broker and packets flow.
4. Create an epic, hit **Plan** → a mission file appears, `/plan` shows its
   chain, `/board` gains Planned cards.
5. Drag a card on the board → the mission `.mmd` on disk changes,
   `/board.mmd` reflects it, a `board_moved` packet is in the feed, and
   `Runes::Kanban.parse` round-trips the file.
6. `/theatre` shows agents with particles moving along edges; `/wall` works
   as a kiosk.
7. `bin/rails test` fully green (baseline 231 runs + the new tests), and
   every POST without the token returns 401.

## Order and dependencies

```
Step 0 (bump, green baseline)
  └─ Slice 1 (shell) ─────────────────────────────┐
  └─ Slice 2A documents ──┐                       │
  └─ Slice 2B connectors ─┼─► Slice 3 auth (3.1) ─┼─► 3.3 plan composer
  └─ Slice 2C plan read ──┤   (gate first!)      ├─► 3.4 board move
  └─ Slice 2D theatre ────┘                       │
  └─ FabricPublisher (3.2) needed by 2A.5 publish and 3.3 — build it early, inside 2A
```

Risks carried from the discovery, restated as plan constraints: auth before
any write (3.1 gates 3.3/3.4 and the connector control path); one active
broker only (2B.3); document serving re-validates sha+ext in the controller
(2A.3/2A.5); kanban writes are last-write-wins + journaled (3.4).
