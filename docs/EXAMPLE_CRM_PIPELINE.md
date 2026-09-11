# The CRM pipeline: a SaaS's engine, not its product surface

`examples/prospect_pipeline.rb` is a working answer to a specific question:
*what if the thing you actually need from an expensive SaaS is its engine, and
that engine is a file you can read?*

The same file takes a raw idea and produces a CRM a small team can act on:

```
idea → goal.md → mission .mmd → advance every todo with a verifier
     → next actions per contact + drafted (never sent) outreach → weekly report
```

It is 431 lines of workflow plus a 297-line format library, it runs offline in
the test suite in about 50 ms, and every artifact it writes is a file a human,
an agent or a Rails app can read. It is **not** a SaaS: it has no auth, no
tenancy, no billing, no landing page. It has the part that usually hides in
controllers, services and background jobs — and it has it in one place.

## Run it

```bash
# offline shape check: what would it write? (needs a provider key for the agent runes)
bin/runes-workflow execute examples/prospect_pipeline.rb idea="Trouver 10 PME"

# point it at a real pipeline_prospect checkout: same folders, same kanban format
PROSPECT_ROOT=/path/to/pipeline_prospect bin/runes-workflow execute examples/prospect_pipeline.rb

# what it costs to run unattended: refuse anything not on your allowlist
RUNES_WORKFLOW_POLICY=config/workflow-policy.json bin/runes-workflow execute examples/prospect_pipeline.rb
```

Without `PROSPECT_ROOT` it writes to `tmp/prospect-pipeline/`, so you can watch
it work without pointing it at anything you care about. The whole run is also
exercised by `test/prospect_pipeline_test.rb` with the provider seam scripted —
the example the docs point at is the file the suite executes.

## What it writes

```
$PROSPECT_ROOT/
├── epics/<slug>_<date>/
│   ├── goal.md                       # the decided goal, with #E-001 in prose
│   └── missions/<mission>.mmd        # the Mermaid kanban, their format
└── crm/
    ├── people.json                   # contacts + stage + last touch
    ├── outbox/<contact>.md           # drafted outreach, never sent
    └── weekly-report.md              # what moved, what is stuck, what is next
```

## Tweak it by changing one line

| You want | Change |
|---|---|
| A different size of plan | the planner prompt: *"between three and six todos"* → *"exactly two"* |
| Different people contacted | `crm[:next_actions].first(2)` → `.first(5)` |
| Your own "next action" rule | one `elsif` in the rule chain (`days >= 14` → your threshold) |
| No verifier for a trusted step | replace the `agent(:verdict)` step with a `ruby(:verdict)` returning a pass |
| A stricter verifier | add a line to the verifier prompt: *"refuse if the report names no file"* |
| English instead of French | the literal prompt strings (`write the report in English`) |
| Send instead of draft | swap the `File.write` in `write_draft` for your channel (`cmd`, an MCP tool) |
| A weekly run | name the top-level scope, then `call` it from a `repeat` — the body does not change |
| Your folder shape | the two `File.join` roots in the `:prepare` scope |
| A different model or provider | `RUNES_LLM_ADAPTER=ruby_llm`, or the provider env vars — no code |

That is the point of the exercise: the *proposition* is malleable. The parts
that are not malleable are the parts you should not write in a DSL anyway —
identity, tenancy, money, law.

## Receipts (measured 2026-09-11)

| | Lines |
|---|---|
| The workflow | **431** (one file, `examples/prospect_pipeline.rb`) |
| The kanban format library it shares | **297** (`lib/runes/kanban.rb`) |
| Its tests (4 workflow + 14 format) | **348** |
| The Rails app it borrows its format from | **3 758** of app code (`app/{models,controllers,services,jobs,serializers,views}`), plus **1 819** of RSpec |

Those two columns are not the same thing, and the difference is the honest
part: the Rails app also owns the *product surface* (forms, pages, JSON API,
serializers) which this workflow deliberately does not replace, and its own
roadmap (`docs/SAAS-ROADMAP.md`) adds five sprints of auth, tenancy, roles,
billing, GDPR and landing-page work on top. What the workflow replaces is the
engine: reading an idea, deciding a goal, planning, executing with verification,
and telling a human what to do next. What it inherits from Runes is the part a
PoC usually gets wrong — and that its own review flagged:

| Property | Where it comes from |
|---|---|
| A redelivered or retried step cannot run twice | `Runes::RequestLedger` |
| A crash mid-run is resumable, and every lifecycle is on disk | the journal |
| A refusal is visible, not silent | `Runes::GuardTelemetry` + `/security` |
| The run is watchable as planned/working/done | `/board` (Mermaid kanban) |
| The whole run can be replayed offline | `bin/runes-replay` |

## What it is not

- **No auth, no tenancy, no billing, no GDPR register, no landing page.** Those
  are product obligations, not intelligence. Keep them in Rails.
- **Not a two-way sync.** The workflow writes mission files; it does not read
  back an edit a human made in `$EDITOR` mid-run (the app does that on read).
- **Not the whole of `pipeline_prospect`.** No multi-turn brainstorming
  transcripts, no document store by SHA-256, no relationship graph, no web UI.
- **Not unsupervised.** The verifier is a second model call, not a proof, and
  the outreach stays a draft: sending is a decision with a human's name on it.

## Why this exists

Runes is not trying to be the SaaS. It is trying to be the reason you can say
no to one: a real workflow, in a file you own, that reads and writes formats
other tools already use, that you can hand to any harness, and that runs with
the safety properties a cron job and a queue never had. Presented next to the
Rails app, that is the argument — *the same engine, 431 lines, and you can
change the verifier before lunch.*
