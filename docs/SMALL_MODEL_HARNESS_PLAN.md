# Coding plan — the LFM3 team

**Status:** proposed · **Revised:** 2026-11-01
**Supersedes:** the text-only specialized-swarm plan in the previous revision
of this document.
**Companion:** `docs/SMALL_MODEL_HARNESS_PRD.md`
**Design source:** `docs/LFM3_TEAM_DISCOVERY.md`
**Cycle:** 43 · **Scope:** contract extension + adapters + conductor +
24-case pilot. The 3-seed product gate is a follow-on only if the pilot
passes.

---

## 1. What this plan delivers

A local **team of contracted roles** drawn from the full LFM3 suite:

- a manifest-backed **identity and capacity contract** (ICC) with an explicit
  **model family** per role;
- **`d1-2B` / `d1-Omni-2B`** for calibrated, typed decisions;
- **`LFM3-VL-2B` / `LFM3-Audio-2B` / `LFM3-Omni-2B`** for perception;
- **`LFM3-1.7B`** for prose: proposals, answers, critique, bounded repair and
  concise rewriting;
- deterministic Ruby for the **conductor, planner, reviewer and verifier**;
- **decline** as a first-class outcome, distinct from **abstain** and
  **escalate**;
- a **code-first verifier** that owns acceptance, including modality,
  provenance and calibration gates;
- a **24-case benchmark** that measures modality routing, perception fidelity,
  proposal divergence, judge calibration, decline correctness, regressions,
  cold/warm cost and per-shape memory.

The plan is additive. The seven rune verbs do not change. The tracked
benchmark never reads `runes-lang/glyphes/tmp` at runtime.

---

## 2. Current state (baseline in the working tree)

The previous cycle landed the text-only contract and supervision layer. It is
uncommitted but green and is the base for this plan.

| area | files | state |
|---|---|---|
| Contract values | `lib/runes/swarm/identity.rb`, `capacity.rb`, `decision.rb` | Done. Text-only allow-lists. |
| Manifests | `config/agents/*.json` (7) | Done: conductor, scout, answerer, critic, verifier, finalizer, escalation. |
| Registry | `lib/runes/swarm/manifest.rb`, `registry.rb` | Done. `BASE_MODEL` hardcoded. |
| Envelope + guard | `lib/runes/swarm/envelope.rb`, `contract_guard.rb` | Done. Text envelope only. |
| Broker + checkpoint | `lib/runes/swarm/capacity_broker.rb`, `checkpoint.rb` | Done. 11 gates. |
| Ledger + receipt | `lib/runes/work_ledger.rb`, `lib/runes/orchestration/receipt.rb` | Done. Text artifacts. |
| Guards | `lib/runes/orchestration/guards.rb`, `violation.rb` | Done. |
| Legacy control | `lib/runes/orchestration/cumulative.rb`, `lib/runes/llm/bonsai_adapter.rb`, `bench/cumulative/` | Done. Baseline only. |
| Tests | `test/swarm_*_test.rb`, `test/orchestration_*_test.rb`, `test/work_ledger_test.rb` | Done. |
| Full suite | `bundle exec rake test` | **984 runs, 5587 assertions, 0 failures, 0 errors, 3 skips.** |

What is **not** there: `ModelFamily`, the new roles/schemas/reasons/hops/gates,
the new manifests, the `D1`/`VL`/`Audio`/`Omni` adapters, `TeamPlan`,
`Conductor`, and `bench/swarm/`.

Current allow-list sizes: `Identity::ROLES` 8, `Capacity::SCHEMAS` 5,
`Decision::HOPS` 6, `Checkpoint::GATES` 11, `WorkLedger::FILES` 15.

---

## 3. Phase 0 — freeze the design and the 24 cases (0.5 day)

### 3.1 Deliverables

- `bench/swarm/cases.json` — 24 cases, six families, gold fields, gold
  anchors, expected shape, expected decision, optional `forbidden_roles`.
- `bench/swarm/fixtures/` — small, redistributable text/image/audio/AV
  fixtures with a `SOURCES.md`. No personal data, no absolute paths.
- `bench/swarm/README.md` — setup, cold/warm, arms, metrics, caveats.
- `bench/swarm/export_fixtures.rb` — deterministic fixture index and SHA-256.
- `.gitignore` — ignore `bench/swarm/runs/`, `bench/swarm/cache/`,
  `bench/swarm/adapters/`, and media larger than the fixture budget.

### 3.2 Case families

| family | cases | examples |
|---|---:|---|
| text QA | 6 | grounded answer; absent value → abstain; conflicting evidence → decline; ambiguous question → clarify/decline |
| vision | 4 | chart value; invoice fields; screen button; object count/box |
| audio | 4 | ASR transcript; French audio → French text; sound event; spoken request → intent |
| audio-video | 2 | speech + visual referent; audio/visual contradiction |
| decision | 6 | intent, team routing, urgency score, extraction, moderation, rerank |
| out of scope | 2 | agentic coding; long-horizon plan |

### 3.3 Case shape

```json
{
  "id": "V2",
  "family": "vision",
  "question": "Quel est le total de la facture ?",
  "evidence": [],
  "media": ["fixtures/invoice-07.png"],
  "gold": { "total": "128,40 €", "anchors": ["page:1", "box:412,88,980,140"] },
  "checks": { "field": "total", "must_match": "128,40" },
  "expected_shape": "see",
  "expected_decision": "accept",
  "forbidden_roles": ["answerer.without_perception"],
  "tags": ["vision", "field"]
}
```

Rules:

- ids are unique and stable; a case is never renumbered;
- `checks` are mechanical; gold anchors are separate from checks;
- a case with no expected decision defaults to `accept`;
- decline cases must name `expected_reason`;
- media paths are relative to `bench/swarm/` and resolve inside it.

### 3.4 Acceptance

- Loading the cases rejects duplicate ids, unknown families, missing media,
  and malformed expectations.
- Every case has at least one check or an expected decision.
- `ruby bench/swarm/runner.rb --dry-run --case T1` lists the checks without a
  model.
- No file under `bench/swarm/` references `runes-lang/glyphes/tmp`.

### 3.5 Commit

`bench: freeze the 24-case LFM3 team benchmark and its fixtures`

---

## 4. Phase 1 — contract values and registry (already landed)

Keep the existing phase. It is recorded here so the commit history is
complete.

### 4.1 `Runes::Swarm::Identity`

```ruby
identity = Runes::Swarm::Identity.new(
  agent_id: "answerer.grounded",
  version: "1.0.0",
  role: :answerer,
  base_model: "LiquidAI/LFM3-1.7B",
  adapter: "prompt:grounded-qa-v1",
  adapter_sha256: nil
)
identity.to_h          # string-keyed hash
identity == other      # value equality
```

Rules:

- `agent_id` matches `/\A[a-z][a-z0-9._-]*\z/`;
- `version` matches `/\A\d+\.\d+\.\d+\z/`;
- `role` is one of the allow-list (extended in Phase 3);
- `adapter_sha256` is `nil` or 64 lowercase hex characters;
- the object is frozen; `from_h` rejects unknown keys.

### 4.2 `Runes::Swarm::Capacity`

```ruby
capacity = Runes::Swarm::Capacity.new(
  can: %i[read_evidence answer_fr cite abstain decline],
  cannot: %i[retrieve execute_tools write_code verify_own_citations],
  max_input_tokens: 262_144,
  max_output_tokens: 320,
  output_schema: "answer.v1"
)
capacity.allows?(:cite)                 # true
capacity.forbids?(:execute_tools)       # true
capacity.overreach(%i[cite write_code]) # [:write_code]
capacity.missing(%i[cite retrieve])     # [:retrieve]
```

Rules:

- `can` and `cannot` are non-empty arrays of symbols;
- `can & cannot` is empty;
- token bounds are positive; deterministic roles use `0` output;
- `output_schema` is one of `SCHEMAS` (extended in Phase 3).

### 4.3 `Runes::Swarm::Decision`

```ruby
decision = Runes::Swarm::Decision.new(
  status: :decline,
  reason_code: :missing_evidence,
  next_hop: :escalation,
  message: "the evidence packet is empty"
)
decision.decline?     # true
decision.body_empty?  # true
```

Rules:

- status is `accept`, `decline` or `escalate`;
- `accept` requires a non-empty body; `decline`/`escalate` require an empty
  body;
- reason and hop are allow-listed (extended in Phase 3);
- `next_hop` is a recommendation; the conductor decides.

### 4.4 `Runes::Swarm::Manifest` and `Registry`

```ruby
manifest = Runes::Swarm::Manifest.load("config/agents/answerer.json")
registry = Runes::Swarm::Registry.new(
  Runes::Swarm::Manifest.load_all("config/agents")
)
registry.fetch("answerer.grounded")
registry.by_role(:answerer)
registry.for_task(required: %i[cite answer_fr])
```

Rules:

- `Manifest::FIELDS` are exactly the identity fields plus `capacities`,
  `requires_evidence`, `forbidden_actions`;
- unknown keys, duplicate ids and bad hashes are errors;
- `forbidden_actions` is a subset of `cannot`;
- the registry rejects duplicate `agent_id` and unknown roles.

### 4.5 Tests and acceptance

`test/swarm_identity_test.rb`, `swarm_capacity_test.rb`,
`swarm_decision_test.rb`, `swarm_manifest_test.rb`, `swarm_registry_test.rb`.

- value round-trip, immutability, unknown keys;
- disjoint `can`/`cannot`, overreach/missing;
- body rules for accept/decline/escalate;
- duplicate id and duplicate role rejection;
- packaging test ships `config/agents/*.json`.

### 4.6 Commit

`swarm: add identity, capacity, decision, manifest and registry contracts`

---

## 5. Phase 2 — envelope, broker, guard, checkpoint, ledger (already landed)

### 5.1 `Runes::Swarm::Envelope`

Tolerant parse of `IDENTITY` / `CAPACITIES` / `DECISION` / `BODY`. Accepts
Markdown headings, bold labels, `KEY:` lines and a JSON object. Missing
sections return `nil` fields, never an exception.

### 5.2 `Runes::Swarm::CapacityBroker`

```ruby
broker = Runes::Swarm::CapacityBroker.new(max_calls: 4, max_wall_s: 120)
broker.authorize(
  manifest: manifest,
  task: { required: %i[read_evidence cite] },
  evidence: evidence,
  calls_used: 1,
  elapsed_s: 3.2
)
```

The broker is a pure function. It returns a `Decision`; an `accept` carries
the control-plane body `"authorized"`, not a model answer. Current order:
manifest → call budget → wall budget → evidence → capabilities → accept.
Phase 3 extends the order.

### 5.3 `Runes::Swarm::ContractGuard`

Compares the parsed envelope to the manifest and returns typed `Violation`s:
`contract_missing`, `identity_missing`, `identity_mismatch`,
`capacity_missing`, `capacity_overreach`, `capacity_conflict`,
`decision_missing`, `decision_invalid`, `body_missing`, `body_forbidden`,
`schema_mismatch`, `forbidden_action`, `contract_invalid`.

A missing envelope is `contract_missing`, never an exception.

### 5.4 `Runes::Swarm::Checkpoint`

Every checkpoint covers the whole `GATES` list; a non-applicable gate is
`:skip`. Current order:

```
call → envelope → identity → capacity → decision → body → schema
     → verifier → progress → budget → route
```

`passed?` is true when no gate failed. `failed_gates` preserves gate order.

### 5.5 `Runes::WorkLedger` and receipts

Current artifacts (15): `task`, `evidence`, `draft`, `critique`,
`violations`, `final`, `draft.cutoff`, `manifest`, `identity`, `capacities`,
`decision`, `decline`, `checkpoints`, `role_receipts`, `transcript`.
Phase 3 adds `triage`, `plan`, `perception`, `notes`, `proposals`, `review`,
`test_status`, `test_output`, `final_test_output` and `calibration`.

`RoleReceipt` records role, agent id, version, adapter hash, decision, status,
prompt/completion hashes, usage and wall time. `RunReceipt` records run id,
model, sampler, arm, case, calls, receipts and status.

Artifacts are limited to 1 MB; the transcript to 8 MB. Paths are sanitized.

### 5.6 Tests and acceptance

`swarm_envelope_test.rb`, `swarm_capacity_broker_test.rb`,
`swarm_contract_guard_test.rb`, `swarm_checkpoint_test.rb`,
`work_ledger_test.rb`, `orchestration_receipt_test.rb`.

- every violation code is injected and caught;
- broker ordering is asserted with spies;
- a checkpoint with a missing gate raises; `:skip` is allowed;
- the ledger writes and reads every artifact; traversal is rejected;
- no accepted artifact exists without a clean guard.

### 5.7 Commit

`swarm: broker capacities, guard the envelope, record checkpoints`

---

## 6. Phase 3 — model families, roster and manifests (1.5 days)

This is the first real change of the new cycle. Without it, a vision or audio
manifest is either impossible or a lie.

### 6.1 `Runes::Swarm::ModelFamily`

New file `lib/runes/swarm/model_family.rb`.

```ruby
family = Runes::Swarm::ModelFamily.fetch("LiquidAI/LFM3-VL-2B")
family.modalities        # [:text, :image, :video]
family.context_tokens    # 131_072
family.output_modes      # [:text]
family.structured?       # false
family.envelope_mode     # :stamp
family.known_limits      # ["no coding", "no multi-turn chat"]
```

Table:

| role family | allowed base models | envelope |
|---|---|---|
| `conductor`, `planner`, `reviewer`, `verifier` | `ruby` | stamp |
| `escalation` | `external` | echo |
| `triage`, `judge` | `LiquidAI/d1-2B`, `LiquidAI/d1-Omni-2B` | stamp |
| `vision` | `LiquidAI/LFM3-VL-2B` | stamp |
| `audio` | `LiquidAI/LFM3-Audio-2B` | stamp |
| `omni` | `LiquidAI/LFM3-Omni-2B` | stamp |
| `ideator`, `answerer`, `critic`, `repairer`, `finalizer`, `scout` | `LiquidAI/LFM3-1.7B`; `LiquidAI/LFM3-1.7B-Base` only with a non-nil `adapter_sha256` | echo |

`ModelFamily` also carries modalities, context length, output modes and known
limits. `Capacity#max_input_tokens` must be `<=` the family context; a
manifest that exceeds it is invalid.

### 6.2 Extend the allow-lists

- `Identity::ROLES` gains `planner reviewer triage judge vision audio omni
  ideator repairer`.
- `Capacity::SCHEMAS` gains `plan.v1 proposal.v1 perception.v1 verdict.v1
  review.v1`.
- `Decision::REASONS` gains `out_of_modality needs_perception needs_vision
  needs_audio needs_omni perception_insufficient low_support proposal_collapse
  repair_exhausted unsafe_request out_of_scope ambiguous_request`.
- `Decision::HOPS` gains `planner reviewer triage judge vision audio omni
  ideator repairer`.
- `Checkpoint::GATES` becomes:
  `call envelope identity capacity decision body schema modality provenance
  verifier calibration progress budget route`.
- `Manifest::DETERMINISTIC_ROLES` gains `planner` and `reviewer`.
- `Manifest::BASE_MODEL` is removed; `expected_base_model` asks
  `ModelFamily` for the role's allowed models.

### 6.3 Broker and guard

`CapacityBroker` order becomes:

```
nil manifest -> no_route
calls budget
wall budget
missing modality
missing evidence
missing capabilities
calibration band
accept
```

The modality check is before evidence so a text role never receives an image
packet and a vision role never receives a text-only task.

`ContractGuard` gains:

- `modality_mismatch` — artifact modality is not allowed by the role family;
- `provenance_missing` — a required anchor is absent or does not resolve;
- `calibration_low` — the judge score is outside the accept band;
- `perception_shape` — a perception artifact is malformed.

Stamp-mode roles skip the `identity` gate with `identity_source: adapter`; the
receipt records it. The `schema`, `modality`, `provenance` and `calibration`
gates carry the enforcement.

### 6.4 Manifests

Add 12 manifests (19 total):

| manifest | role | base model | schema |
|---|---|---|---|
| `planner.microstep` | planner | ruby | `plan.v1` |
| `reviewer.manager` | reviewer | ruby | `review.v1` |
| `triage.d1` | triage | `LiquidAI/d1-2B` | `verdict.v1` |
| `triage.audio` | triage | `LiquidAI/d1-Omni-2B` | `verdict.v1` |
| `judge.d1` | judge | `LiquidAI/d1-2B` | `verdict.v1` |
| `judge.omni` | judge | `LiquidAI/d1-Omni-2B` | `verdict.v1` |
| `perceiver.vision` | vision | `LiquidAI/LFM3-VL-2B` | `perception.v1` |
| `perceiver.audio` | audio | `LiquidAI/LFM3-Audio-2B` | `perception.v1` |
| `perceiver.omni` | omni | `LiquidAI/LFM3-Omni-2B` | `perception.v1` |
| `ideator.direct` | ideator | `LiquidAI/LFM3-1.7B` | `proposal.v1` |
| `ideator.alternative` | ideator | `LiquidAI/LFM3-1.7B` | `proposal.v1` |
| `repairer.bounded` | repairer | `LiquidAI/LFM3-1.7B` | `answer.v1` |

Existing manifests stay: `conductor.router`, `scout.retriever`,
`answerer.grounded`, `critic.claims`, `finalizer.concise`,
`verifier.mechanical`, `escalation.frontier`.

Manifest rules:

- `requires_evidence` is `true` for grounded text and perception roles;
- `forbidden_actions` is a subset of `cannot`;
- a `Base` model requires a non-nil `adapter_sha256`;
- `max_input_tokens` respects the family context;
- deterministic roles use `max_output_tokens: 0`.

### 6.5 Ledger and receipts

`WorkLedger::FILES` gains `triage`, `plan`, `perception`, `notes`,
`proposals`, `review`, `test_status`, `test_output`, `final_test_output`,
`calibration`.

Media and long documents can exceed 1 MB. The adapter chunks by page/time and
writes a compact evidence index plus chunk files, or declines. It never
silently truncates an artifact that still carries anchors.

`RoleReceipt` gains `model_family`, `modalities`, `calibration`, `divergence`,
`repair_round`, `cold`/`warm`. `RunReceipt` gains `shape`, `calibration` and
`peak_memory_mb`.

### 6.6 Tests

`test/swarm_model_family_test.rb`, plus updates:

- family lookup, unknown model, context bound, Base-without-adapter;
- every new role is accepted by `Identity` and `Checkpoint`;
- every new schema is accepted by `Capacity`;
- every new reason/hop is accepted by `Decision`;
- every new gate is required in order;
- all 19 manifests load and validate; duplicate ids rejected;
- broker ordering: modality before evidence before capabilities;
- guard catches each new violation in both echo and stamp mode;
- ledger writes the new artifacts; receipts carry the new fields.

### 6.7 Acceptance

- `Runes::Swarm::Manifest.load_all("config/agents")` returns 19 manifests.
- A `perceiver.vision` manifest cannot load with a text model.
- A text role cannot authorize an image packet.
- A `d1` manifest cannot use `answer.v1`.
- `bundle exec rake test` is green.

### 6.8 Commit

`swarm: add model families, the team roster and the new contract gates`

---

## 7. Phase 4 — adapters and role profiles (2 days)

### 7.1 Adapters

| adapter | seam | output |
|---|---|---|
| `Runes::LLM::Lfm3Adapter` | command/server text | text |
| `Runes::LLM::D1Adapter` | `system_one(state, questions, media:)` | typed `verdict.v1` |
| `Runes::LLM::VisionAdapter` | image/video/document | text → `perception.v1` |
| `Runes::LLM::AudioAdapter` | audio/text | text → `perception.v1` |
| `Runes::LLM::OmniAdapter` | joint audio-video | text → `perception.v1` |

Common contract:

```ruby
result = adapter.call(input, role: "answerer", max_tokens: 320)
# => { ok:, content:, usage:, finish_reason:, status:, error:, family:, modalities: }
```

- command mode builds argv explicitly (no shell), writes the prompt to
  stdin, cleans ANSI/control tokens and prompt echoes;
- server mode delegates to `OpenAICompatModel`;
- `available?` checks the CLI script, the model path (when path-like) and the
  server base URL;
- `from_env` reads `LFM3_MODE`, `LFM3_MODEL`, `LFM3_PYTHON`, `LFM3_CLI`,
  `LFM3_BASE_URL`, `LFM3_API_KEY`, `LFM3_MAX_TOKENS`, and the per-family
  `LFM3_VL_MODEL`, `LFM3_AUDIO_MODEL`, `LFM3_OMNI_MODEL`, `LFM3_D1_MODEL`,
  `LFM3_D1_OMNI_MODEL`.

`D1Adapter` does not sample and does not generate tokens. It sends a state,
a list of typed questions and optional media, and returns typed answers with
probabilities. It is the only adapter allowed to emit `verdict.v1`.

### 7.2 CLI scripts

- `bench/swarm/lfm3_cli.py` — text; mirrors the legacy `bonsai_cli.py`
  contract: `--model`, `--python`, `--max-tokens`, `--temperature`, `--top-p`,
  `--top-k`, `--repetition-penalty`; prompt on stdin; answer on stdout; errors
  on stderr with a non-zero exit.
- `bench/swarm/lfm3_media_cli.py` — `--family vision|audio|omni`, `--input
  PATH`, `--max-tokens`; one media input per call; text on stdout.
- `bench/swarm/d1_cli.py` — `--model`, `--state`, `--questions JSON`,
  `--media PATH`; typed JSON on stdout, no sampling flags.

All scripts support `mlx_vlm.generate` and a `transformers` fallback, selected
by `--backend`. A missing binary is `:infra`, never a model answer.

### 7.3 `Runes::LLM::RoleProfile`

```ruby
profile = Runes::LLM::RoleProfile.new(
  role: :answerer,
  instructions: Bench::Swarm::Prompts::ANSWERER,
  max_tokens: 320,
  sampler: nil,
  tools: [],
  envelope_mode: :echo,
  adapter: "prompt:grounded-qa-v1",
  adapter_sha256: nil
)
profile.prompt(task: question, evidence: evidence, manifest: manifest)
```

`prompt` includes, in order:

1. the assigned identity block, exactly as the manifest declares it;
2. the capacity block (`can`, `cannot`, token budgets, output schema);
3. the output contract: `IDENTITY`, `CAPACITIES`, `DECISION`, `BODY`;
4. the role instructions;
5. the task and the validated evidence/perception packet.

The model echoes the identity/capacity blocks; it does not invent them. The
prompt says: "Copy the assigned values exactly. Do not add a capability. If
the task is outside these capacities, return `status: decline` with a reason
code and an empty body."

**One micro-task per prompt.** The profile never includes a multi-step plan, a
transcript, or a request to self-manage the chain. The conductor supplies
exactly one role instruction and one output schema.

Stamp-mode profiles (`d1`, perception) do not ask for an envelope. The adapter
writes the envelope from the manifest and the typed artifact; the profile
supplies the typed question set or the media instruction.

### 7.4 Samplers

- `DEFAULT_SAMPLER = { temperature: 0.1, top_k: 50, repetition_penalty: 1.1 }`
  for answer/critic/repair;
- `IDEATION_SAMPLER = { temperature: 0.35, top_p: 0.95, top_k: 50 }` for
  ideators;
- `MATH_SAMPLER = { temperature: 1.0, top_p: 0.95, top_k: 20 }` only for math
  cases and labelled;
- `DEFAULT_MAX_TOKENS = 320`;
- `enable_thinking` is off for envelope/schema calls and recorded in the
  receipt when on.

### 7.5 Tests

- `test/lfm3_adapter_test.rb`: argv order, stdin, sampler flags, server
  payload, output cleaning, missing CLI/model, `from_env`, math sampler.
- `test/d1_adapter_test.rb`: typed questions, no sampling flags, probabilities
  in `[0,1]`, media routing, stamp envelope, missing binary.
- `test/media_adapters_test.rb`: one media input per call, family/model
  pairing, provenance fields, chunking, unreadable media → decline.
- `test/role_profile_test.rb`: the prompt contains the assigned `agent_id`,
  version and adapter hash; per-role `max_tokens`; the decline instruction;
  tools are listed only for the scout; stamp mode omits the echo request.
- A live test is skipped unless `RUNES_LFM3=1`; it asserts a non-empty
  response and a parseable envelope, not a correct answer.

### 7.6 Acceptance

- A fake command runner receives exactly the documented argv and the prompt
  on stdin.
- A fake transport receives the documented OpenAI-compatible payload.
- `require "runes"` still succeeds without Python or a model.
- The live tests are opt-in and do not run in `rake test`.
- No adapter calls `::JSON`; all JSON goes through `Runes::Json`.

### 7.7 Commit

`llm: add the LFM3 family adapters and the echo/stamp role profiles`

---

## 8. Phase 5 — team plan and conductor (2.5 days)

### 8.1 `Runes::Orchestration::TeamPlan`

New file `lib/runes/orchestration/team_plan.rb`.

```ruby
plan = Runes::Orchestration::TeamPlan.build(
  shape: :answer_full,
  task: task,
  evidence: evidence,
  media: media,
  registry: registry,
  budgets: { calls: 8, steps: 12, wall_s: 300 }
)
plan.shape          # :answer_full
plan.steps          # ordered Step objects: role, capabilities, schema, anchors
plan.anchors        # { proposal_a: "...", proposal_b: "...", review: "...", repair: "..." }
plan.acceptance     # mechanical checks + d1 questions + thresholds
plan.to_h           # plan.v1
```

The planner is Ruby. It writes `task.md` verbatim, indexes evidence/perception
by hash, reserves unique anchors, and defines the acceptance checks. It never
asks a model to plan.

Shape selection:

- `Shape.select(triage_verdict, task_profile, registry)` returns one of
  `decide`, `answer-lite`, `answer-full`, `see`, `hear`, `watch`, `escalate`;
- a missing required role or modality is a decline, not a downgrade;
- the model never selects its own shape.

### 8.2 `Runes::Orchestration::Conductor`

```ruby
conductor = Runes::Orchestration::Conductor.new(
  registry: registry,
  ledger: Runes::WorkLedger.new(root: run_dir, run_id: "run-01"),
  guards: Runes::Orchestration::Guards.new(task: task, evidence: evidence),
  verifier: verifier,
  broker: Runes::Swarm::CapacityBroker.new(max_calls: 8, max_wall_s: 300),
  models: {
    triage: d1,
    judge: d1,
    vision: vl,
    audio: audio,
    omni: omni,
    ideator: lfm3,
    answerer: lfm3,
    critic: lfm3,
    repairer: lfm3,
    finalizer: lfm3
  },
  profiles: profiles,
  calibration: calibration,
  max_calls: 8,
  max_steps: 12,
  max_wall_s: 300
)
result = conductor.run(task: task, evidence: evidence, media: media)
```

`Result` exposes `status`, `shape`, `final`, `decision`, `route`,
`checkpoints`, `violations`, `receipt`, `ledger`, `error`, `elapsed_s`.
`route` is an ordered array of `{ phase:, role:, agent_id:, decision:, status:,
checkpoint:, call: }` entries; `checkpoint` is the `Checkpoint#to_h` for that
step.

### 8.3 The loop

```
1. write task/evidence; start receipt; steps = 0; shape = nil.
2. triage: d1 typed verdict; conductor validates against registry, budgets
   and policy. Out of scope / unsafe / no shape -> decline or escalate; stop.
3. build the TeamPlan for the shape. The model never sees this plan.
4. perceive (if the shape needs it):
     a. authorize each perception role; record :budget/:capacity.
     b. call one modality per role; record :call.
     c. stamp the envelope; record :envelope, :schema, :modality.
     d. provenance gate; record :provenance.
     e. d1 judge: sufficiency; AV judge: agreement. If insufficient ->
        one targeted re-perception, or decline missing_evidence.
5. ideate A || B (answer-full only), fresh contexts, distinct anchors:
     a. authorize both; record :budget/:capacity.
     b. call both; record :call.
     c. parse/guard each; record :identity/:capacity/:schema/:decision/:body.
     d. divergence check; if identical -> :proposal_collapse, count one.
6. select (d1 judge): score A/B; apply bands; record :calibration.
7. solve (answerer): one instruction, validated evidence/perception and the
   selected proposal; record the full gate order.
8. test: run every mechanical check; write test-status.txt/test-output.log;
   non-blocking.
9. review: d1 per-claim support/contradiction + reviewer.manager; write
   review.md; exactly one repair round if needed.
10. repair (one round): answerer-family repairer; no new facts; re-run gates.
11. verify: rerun every mechanical check and d1 support; authoritative.
12. finalize (optional): concise rewrite; verify again; a decline leaves the
    verified answer standing.
13. write identity/capacities/decision/decline/checkpoints/role_receipts/
    triage/plan/perception/notes/proposals/review/test logs/calibration;
    finish receipt.
```

### 8.4 Routing rules

- The conductor owns the hop. `Decision#next_hop` is a recommendation; the
  conductor checks it against the shape and the registry.
- A failed checkpoint is a hard stop for that step. The conductor may route
  to another role only after recording the failure; it never forwards the raw
  body.
- The conductor never sends a multi-step plan or the transcript. Each call
  gets one role instruction, the validated artifact and the assigned
  identity/capacity block.
- A decline never re-calls the same role with the same input. If the only hop
  is the same role, the conductor declines with `no_route`.
- A frontier/human hop is allowed only when `escalation` is configured.
  Otherwise the run ends `:declined` with `escalation_unavailable` in the
  ledger, not a silent generalist call.
- The escalation adapter is opaque: if it returns an envelope, the guard
  checks it; if it returns a plain body, the conductor records `escalated` and
  does not claim local acceptance.
- The verifier is not a model role; it does not consume `max_calls` and cannot
  be declined by a manifest.
- The finalizer is optional. If it declines, the verified answerer body is the
  final artifact; the decline is recorded, not hidden.
- A stale artifact from a prior run is never reused: fresh run id, `progress`
  gate, no file-existence success targets.
- A counterexample from the reviewer is validated by an executable or
  brute-force check before it can trigger a repair.

### 8.5 Status taxonomy

`ok`, `repaired`, `declined`, `escalated`, `unverified`, `infra`, `error`,
`truncated`, `empty_stop`, `no_progress`, `proposal_collapse`.

`declined` and `escalated` are successful control-plane outcomes: they are
counted in the decline metrics, not in the false-answer rate.

### 8.6 Tests

`test/swarm_conductor_test.rb` and `test/team_plan_test.rb` with
`ScriptedModel` and fake adapters:

- clean `answer-lite` → `:ok`, expected calls, one receipt;
- triage out of scope → `:declined` or `:escalated`, no local call;
- triage selects `decide` → no text call;
- `see` shape with a VL adapter → perception then answer;
- missing media → `:declined` / `missing_evidence`, no text call;
- provenance miss → `:unverified`, no next role;
- modality mismatch → `:unverified`;
- d1 sufficiency low → one re-perception or `:declined`;
- A/B collapse → `:proposal_collapse`, one proposal counted;
- A/B divergence → judge chooses one, calibration recorded;
- answerer accept + verifier fail + reviewer + repair → `:repaired`;
- critic decline → `:escalated` (or `:declined`), never a blind repair;
- repair returns the same body → `:no_progress`;
- a second repair is refused → `:repair_exhausted`;
- contract mismatch → `:unverified`, no accept;
- a failed `envelope` checkpoint never calls the next role (spy stays
  uncalled);
- every route entry has a checkpoint with all 14 gates in order;
- `max_steps` stops the loop even when the call budget remains;
- budget exhausted before the first call → `:declined` /
  `budget_exhausted`;
- wall-clock budget exhausted → `:infra` or `:declined` with the budget
  reason (decide once and test it);
- finalizer decline → `:ok` with the verified answerer body and a recorded
  finalizer decline;
- the transcript and the team plan are never part of a prompt;
- an anchor occurs exactly once before and after parallel ideation.

### 8.7 Acceptance

- A fake run writes every contract artifact and a role receipt per call.
- No accepted artifact exists without a clean contract guard and a clean
  verifier.
- Every step has a checkpoint; `unvalidated_hops == 0` is asserted.
- A failed checkpoint stops the step; the next role is never called with the
  failed artifact.
- A decline is routed or escalated; the same role is never retried with the
  same input.
- A repair round is at most one; a second request is `:repair_exhausted`.
- `bundle exec ruby -Ilib -Itest test/swarm_conductor_test.rb` is green.

### 8.8 Commit

`orchestration: add the shape router and the supervised LFM3 conductor`

---

## 9. Phase 6 — benchmark runner and report (2 days)

### 9.1 Arms

| arm | composition | purpose |
|---|---|---|
| `solo-1.7B` | one text call | text baseline |
| `solo-VL` | one VL call | vision baseline |
| `solo-Audio` | one Audio call | audio baseline |
| `solo-Omni` | one Omni call | AV baseline |
| `d1-only` | triage → judge → verifier | decision baseline |
| `text-lite` | answerer + d1 judge + verifier | cheap text team |
| `text-full` | ideate A‖B → judge → answerer → critic → judge → repair | memdoor parity |
| `perception+text-lite` | VL/Audio/Omni → text-lite | modality lift |
| `team-full` | shape router + all roles | candidate |
| `frontier-1x` | external reference | gap measurement |
| `same-model-3x` | 1.7B answer → critic → repair | control; never the candidate |
| `profile-only` vs `adapter` | text roles with/without LoRA | specialization honesty |

`solo-1.7B` uses `bench/swarm/manifests/generalist.json` and the same envelope
contract as the specialists, so the comparison isolates specialization rather
than contract compliance. `same-model-3x` runs the legacy `Cumulative` class
and is scored with the same checks; it is never the candidate. The legacy
`BonsaiAdapter` and `bench/cumulative/` remain controls.

### 9.2 CLI

```bash
ruby bench/swarm/runner.rb \
  --arm team-full \
  --seeds 0 \
  --case T1 --case V2 --case A3 \
  --command "bench/swarm/lfm3_cli.py --model $LFM3_MODEL --python $LFM3_PYTHON" \
  --out bench/swarm/results/2026-11-01-team-full.md \
  --json bench/swarm/results/2026-11-01-team-full.json
```

Options:

- `--arm` — one of the arms;
- `--seeds 0,1,2` or `--runs 3`;
- `--case ID` repeated or comma-separated; default all 24;
- `--cases PATH`;
- `--command`, `--base-url`, `--model`, `--api-key`;
- per-family model flags: `--vl-model`, `--audio-model`, `--omni-model`,
  `--d1-model`, `--d1-omni-model`;
- `--temperature`, `--top-k`, `--repetition-penalty`, `--top-p`,
  `--max-tokens`;
- `--max-wall-s`, `--timeout`;
- `--runs-dir`, `--cache-dir`, `--results-dir`;
- `--baseline PATH` for regressions;
- `--calibration PATH` for bands;
- `--out`, `--json`;
- `--reuse`, `--no-cache`;
- `--dry-run` prints the role prompts and checks; calls no model;
- `--strict` exits 1 on any non-infra case failure.

### 9.3 Runner flow

For every `(case, arm, seed)`:

1. create a fresh `WorkLedger` under `bench/swarm/runs/`;
2. build the arm's registry, shape and profiles;
3. run the conductor (or the legacy loop for `same-model-3x`);
4. independently re-score the final artifact with `Checks`;
5. grade the decision and shape against `expected_decision`/
   `expected_shape`/`expected_reason`;
6. record the route, role receipts, checkpoints, calibration scores, decline
   reasons, contract violations, calls, wall time, cold/warm and peak memory;
7. hand the row to `Report`.

Infra rows are named and excluded from the accuracy denominator. A timeout, a
missing binary, an unavailable server or an unreadable fixture is `infra`,
never a decline.

The `same-model-3x` arm has no envelope. Its row's `decision` is inferred from
the final artifact (`empty` → `decline`, abstention phrase → `accept` with
`abstain: true`, otherwise `accept`) and is labelled `inferred: true`. Do not
compare its contract-compliance numbers to the envelope arms.

### 9.4 Report

Markdown + JSON with:

- a summary table per arm: task pass, checks passed/total, shape accuracy,
  perception fidelity, proposal divergence, selection quality, judge ECE,
  decline precision/recall, false-answer rate, contract violations,
  checkpoint pass rate, unvalidated hops, first-failure gate, regressions,
  calls by model/role, wall time, cold/warm, peak memory;
- per-case detail: status, shape, decision, reason, route, checkpoints,
  checks, calibration, violations, final artifact and raw ledger artifacts;
- the denominator: graded rows, infra rows and excluded rows;
- provenance: each model revision, quantization, runtime, sampler, seed (or
  `seed: null`), cases file SHA-256 and calibration file SHA-256.

Decline precision = true declines / predicted declines; recall = true declines
/ expected declines. False-answer rate = accepted non-empty bodies on
expected-decline rows / expected-decline rows. A false decline on an
answerable case is a regression, not a success.

### 9.5 Tests

`test/bench_swarm_test.rb` with fake models and a fake escalation:

- case loading rejects duplicate ids, unknown families, missing media and
  malformed expectations;
- decision and shape grading accept the expected values and reject a
  mismatch;
- each arm selects the right roles;
- decline precision/recall and false-answer rate are computed from a small
  fixture;
- checkpoint pass rate, unvalidated hops and first-failure gate are computed
  from a small fixture;
- calibration ECE/Brier are computed from a small fixture;
- infra rows are excluded from the denominator;
- the report refuses to overwrite an existing path;
- a dry run calls no model;
- the runner never reads `runes-lang/glyphes/tmp`.

### 9.6 Acceptance

- `ruby bench/swarm/runner.rb --dry-run --case T1` prints the prompts and
  checks without a model.
- A fake-model run over all 24 cases writes a Markdown + JSON report and
  every row has a shape, a decision and at least one checkpoint.
- The report shows the six families separately and the multimodal arms
  separately from text.
- The report shows checkpoint pass rate, unvalidated hops (0 on accepted
  runs), first-failure gate distribution and calibration metrics.

### 9.7 Commit

`bench: run the contracted LFM3 team over the 24-case benchmark`

---

## 10. Phase 7 — pilot, analysis, go/no-go (1.5 days)

### 10.1 Run matrix

- `solo-1.7B`, `solo-VL`, `solo-Audio`, `solo-Omni`, `d1-only`,
  `text-lite`, `text-full`, `perception+text-lite`, `team-full`:
  24 cases × 1 seed for the pilot; warm server preferred; one cold command run
  per family for latency.
- `frontier-1x`: optional, only if an endpoint is configured.
- `same-model-3x`: one seed, as a control.
- `profile-only` vs `adapter`: only if an adapter exists; otherwise report
  `profile-only` and say so.

### 10.2 Analysis

- **Text lift:** `text-lite` task-pass minus `solo-1.7B` on the text subset.
- **Modality lift:** `perception+text-lite` and `team-full` minus their
  matching solo baselines on the vision/audio/AV subsets.
- **Shape accuracy:** selected shape vs expected shape per family.
- **Perception fidelity:** field precision/recall, anchor validity, invented
  anchor rate, WER where gold exists.
- **Proposal divergence and selection:** A/B difference rate; chosen proposal
  pass rate vs best/worst; judge ECE/Brier/AUC.
- **Claim support and repair:** unsupported-claim precision/recall;
  false-accept rate; pass before/after repair; repair-round usage.
- **Decline correctness:** precision/recall on out-of-scope and the
  unsupported subset; over-decline rate on answerable cases.
- **Contract compliance:** identity mismatches, capacity overreach, modality
  mismatch, provenance missing, unvalidated hops (must be 0), stale artifacts
  (must be 0).
- **Supervision cost:** checkpoint pass rate, first-failure gate
  distribution. A low pass rate means the role prompt, manifest or adapter is
  wrong; it is not a reason to weaken the guard.
- **Cost:** calls by model/role, tokens, wall time, cold vs warm, per-shape
  peak memory.
- **Gap closure:** per family, with the matching baseline; `n/a` when the
  denominator is zero or negative.
- **Regressions:** cases a solo baseline passed and the team failed.

### 10.3 Decision record

`bench/swarm/results/2026-11-01-pilot.md` and `.json`:

- the exact model/revision/quantization/runtime/sampler per family;
- the arm table with denominators and infra rows;
- the calibration file and its SHA-256;
- the per-case failures with the raw ledger path;
- a verdict: `GO`, `NO-GO`, or `INCONCLUSIVE`;
- one paragraph naming the next thread, or saying the thread is closed.

### 10.4 Acceptance

- The pilot covers all 24 cases and every arm in the run matrix.
- Every claim in the decision record points to a report row.
- No "promising" without a number.
- The negative-result path is written, not implied.

### 10.5 Commit

`docs: record the LFM3 team pilot and the go/no-go`

---

## 11. Phase 8 — hardening, docs, optional workflow adapter (1 day)

### 11.1 Docs

- `bench/swarm/README.md`: setup, cold/warm, arms, metrics, caveats.
- `docs/SMALL_MODEL_HARNESS_PRD.md`: link the plan and the report; update the
  pilot table.
- `ENHANCEMENT.md`: a short "Cycle 43" entry with the verdict and the next
  thread.
- `DEVELOPMENT_LOG.md`: one entry per phase commit.
- If the harness is intended for embedders, add a short section to
  `docs/WORKFLOWS.md` showing a `ruby` step calling `Conductor`. Do not add a
  new verb.

### 11.2 Optional workflow adapter

Only after the library and benchmark are green:

```ruby
ruby(:answer) do
  Runes::Orchestration::Conductor.new(
    registry: Runes::Swarm::Registry.new(
      Runes::Swarm::Manifest.load_all("config/agents")
    ),
    ledger: Runes::WorkLedger.new(root: run_dir, run_id: "wf-answer"),
    guards: Runes::Orchestration::Guards.new(task: task, evidence: evidence),
    verifier: verifier,
    broker: Runes::Swarm::CapacityBroker.new(max_calls: 4),
    models: { answerer: Runes::LLM::Lfm3Adapter.from_env },
    profiles: { answerer: answerer_profile },
    max_calls: 4
  ).run(task: task, evidence: evidence).final
end
```

The workflow owns the evidence and the verifier; the conductor owns the loop.
If this adapter needs more than ~40 lines, it is out of scope for v0.

### 11.3 Hardening checklist

- `bundle exec rake test` green.
- `RUNES_WASM=real` file still green (no transport changes expected).
- No new runtime gem; the only `runes.gemspec` change is adding
  `config/agents/*.json` to the file allow-list.
- Packaging test still passes and asserts all 19 manifests ship; no `tmp/`,
  `docs/epics/`, or secrets in the gemspec.
- `require "runes"` succeeds without `wasmtime`, Python, or a model.
- No test touches the network; `test_helper` already strips provider keys.
- `bench/swarm/cases.json` contains no personal data or absolute paths.
- No unvalidated hop: the conductor test asserts `unvalidated_hops == 0`, and
  a failed checkpoint never reaches the next role.
- No stale artifact: a fresh run id and the `progress` gate are asserted.
- The legacy `bench/cumulative/` suite still passes.
- `discovery.md` and `docs/2609.20804v1.pdf` are not staged.
- No file under `bench/swarm/` reads `runes-lang/glyphes/tmp`.

### 11.4 Commit

`docs: close the LFM3 team cycle`

---

## 12. Test matrix (summary)

| layer | test | fake | what it proves |
|---|---|---|---|
| identity | `swarm_identity_test.rb` | values | validation, immutability, round-trip |
| capacity | `swarm_capacity_test.rb` | values | disjointness, overreach, missing, subset |
| decision | `swarm_decision_test.rb` | values | status/reason/hop, body rules |
| model family | `swarm_model_family_test.rb` | table | allowed models, context, modalities, Base rule |
| envelope | `swarm_envelope_test.rb` | strings | tolerant headings, JSON, missing sections |
| manifest | `swarm_manifest_test.rb` | JSON files | required keys, duplicates, bad hashes, family |
| registry | `swarm_registry_test.rb` | manifests | register/fetch/by-role, duplicates |
| broker | `swarm_capacity_broker_test.rb` | manifests | modality/evidence/capability/calibration/budget order |
| guard | `swarm_contract_guard_test.rb` | envelopes | every contract violation, echo/stamp |
| checkpoint | `swarm_checkpoint_test.rb` | gate maps | pass/fail/skip, failed gates, round-trip |
| team plan | `team_plan_test.rb` | registry | shape, DAG, anchors, acceptance, budgets |
| conductor | `swarm_conductor_test.rb` | `ScriptedModel` | shape, fan-out, accept/decline/escalate, no blind retry, repair, no-progress, checkpoint gating |
| text adapter | `lfm3_adapter_test.rb` | fake runner/transport | command/server, sampler, cleaning |
| d1 adapter | `d1_adapter_test.rb` | fake runner | typed questions, probabilities, stamp envelope |
| media adapters | `media_adapters_test.rb` | fake runner | one media input, provenance, chunking |
| profile | `role_profile_test.rb` | manifests | assigned identity/capacities, echo vs stamp |
| bench | `bench_swarm_test.rb` | fake model | cases, arms, shapes, report, infra, metrics |
| ledger | `work_ledger_test.rb` | tmpdir | new artifacts, snapshot, path safety |
| legacy | `cumulative_orchestrator_test.rb` | `ScriptedModel` | the control still works |
| full | `rake test` | — | no regression in the parent suite |

---

## 13. Commit plan

| # | commit | contents |
|---|---|---|
| 1 | `bench: freeze the 24-case LFM3 team benchmark and its fixtures` | Phase 0; cases, fixtures, README, export tool, `.gitignore`. |
| 2 | `swarm: add identity, capacity, decision, manifest and registry contracts` | Phase 1; value objects, manifest, registry, tests. |
| 3 | `swarm: broker capacities, guard the envelope, record checkpoints` | Phase 2; envelope, broker, guard, checkpoint, ledger artifacts, tests. |
| 4 | `swarm: add model families, the team roster and the new contract gates` | Phase 3; `ModelFamily`, allow-lists, 12 manifests, broker/guard/gate changes, receipts. |
| 5 | `llm: add the LFM3 family adapters and the echo/stamp role profiles` | Phase 4; `D1`/`VL`/`Audio`/`Omni`/text adapters, CLI scripts, profiles, tests. |
| 6 | `orchestration: add the shape router and the supervised LFM3 conductor` | Phase 5; `TeamPlan`, `Shape`, `Conductor`, tests. |
| 7 | `bench: run the contracted LFM3 team over the 24-case benchmark` | Phase 6; runner, checks, arms, report, tests. |
| 8 | `docs: record the LFM3 team pilot and the go/no-go` | Phase 7; report, PRD update, `ENHANCEMENT.md`. |
| 9 | `docs: close the LFM3 team cycle` | Phase 8; hardening, workflow adapter if any. |

Do not commit `discovery.md` or `docs/2609.20804v1.pdf`. Do not commit
`bench/swarm/runs/`, `bench/swarm/cache/` or `bench/swarm/adapters/`; commit
only `bench/swarm/results/*.md`/`*.json` when they are the decision record.
Keep the legacy `bench/cumulative/` files; they are the baseline.

---

## 14. Definition of done

The cycle is done when:

1. Nineteen production manifests load and validate; every manifest declares
   a model family allowed for its role.
2. The registry is the only source of identity; the contract guard rejects
   identity mismatches, capacity overreach, modality mismatch, provenance
   misses, calibration lows, missing bodies and forbidden actions.
3. Every role call has a checkpoint with all 14 gates; a failed checkpoint
   stops the step and no artifact reaches the next role without a pass
   (`unvalidated_hops == 0`).
4. The conductor sends one micro-task per call and never sends a multi-step
   plan or the transcript.
5. The conductor selects a shape, routes declines and escalations, never
   blindly retries the same role, and records `escalation_unavailable` instead
   of falling back to a generalist.
6. `d1` owns typed decisions; perception roles emit only `perception.v1`;
   text roles emit `proposal.v1`, `answer.v1` or `critique.v1`; the verifier
   is code and overrides an `accept` envelope.
7. The ledger preserves triage, plan, perception, notes, proposals, review,
   test logs, calibration, identity, capacities, decision, decline,
   checkpoints and role receipts, and can snapshot them into `DocStore`.
8. The benchmark runs the 24 cases across the arms and reports task pass,
   shape accuracy, perception fidelity, proposal divergence, judge
   calibration, decline precision/recall, false-answer rate, contract
   violations, checkpoint pass rate, unvalidated hops, first-failure gate,
   regressions, cold/warm cost and per-shape memory with an explicit
   denominator.
9. The pilot is run over all 24 cases and the verdict is `GO`, `NO-GO`, or
   `INCONCLUSIVE`.
10. `bundle exec rake test` is green; the default suite makes no live call.
11. The legacy cumulative benchmark and tests still pass.
12. `ENHANCEMENT.md` names the next thread in one paragraph, or says the
    thread is closed.

---

## 15. Rollback and stop rules

- The contract layer and conductor are additive: remove the `require_relative`
  lines and the new files; no schema, no migration, no runtime state.
- The benchmark is repo-local and not packaged: deleting `bench/swarm/` leaves
  the gem unchanged.
- If the pilot is `NO-GO`, **stop**. Keep the matching solo baselines and the
  legacy control, publish the negative result, and do not add a fourth
  same-model call, a larger prompt or a bigger model to rescue it.
- If a model cannot emit its contract reliably, try stamp mode or a stricter
  JSON-mode prompt before declaring failure. v0 does not add a contract-repair
  call; a contract failure is `:unverified`, not an excuse to weaken the
  guard.
- If `d1` calibration is poor, widen the abstain band and use the judge as a
  signal only; do not remove the calibration gate.
- If the decline rate is too high, measure precision/recall and the
  answerable-case coverage. Do not remove declines to raise task pass.
- If the checkpoint pass rate is low, fix the role prompt, manifest or adapter
  or declare the role unfit. Do not remove a checkpoint to make the numbers
  look better.
- If the guards produce false positives on clean cases, fix the guard before
  running the pilot. A verifier that rejects correct answers is worse than no
  verifier.
- If the warm server cannot carry the sampler, report cold-only and defer the
  economics claim. Do not fabricate warm numbers.
- If the full suite does not fit, load per shape and report peak memory per
  shape; never claim "the whole suite on a phone."

---

## 16. The one-sentence plan

Extend the contract layer with model families and the new roles/schemas/gates,
add the family adapters and the echo/stamp profiles, then the shape router and
the supervised conductor; prove with fakes that identity, modality,
provenance, calibration and decline are enforced; then run the 24-case pilot
and let modality lift, calibration, decline correctness and cost — not the
architecture — decide whether the team is worth it.

---

## 17. Addendum — JEPA latent layer (J0/J1/J2)

**Status:** optional, benchmark-gated, after Phase 6. J0 is the default
extension; J1 is a spike; J2 is research. The 24-case pilot and its commit
plan are unchanged.

### 17.1 J0 — frozen index (insert after Phase 6)

| path | purpose |
|---|---|
| `lib/runes/swarm/view.rb` | `View`, `ViewSet`, good/bad pair rules, trims, anchors |
| `lib/runes/swarm/alignment.rb` | load/project/score/stable?; matrix metadata |
| `lib/runes/swarm/latent.rb` | `Latent`; vector ref, rank, residual |
| `lib/runes/swarm/latent_card.rb` | compact anchor-preserving card |
| `lib/runes/swarm/nuisance_probe.rb` | deterministic transform probe |
| `config/alignments/*.json` | matrix, dims, fit stats, hash |
| `bench/latent/embed.py` | frozen features from the suite |
| `bench/latent/fit.py` | whiten + Procrustes |
| `bench/latent/evaluate.py` | mutual 10-NN, R@1, residual, gap |
| `bench/swarm/latent_cases.json` | the 8-case latent suite |

1. `View`/`ViewSet`: `state_id`, `rendering_sha256`, `modality`, `nuisance`,
   `trim`, `anchors`; good/bad pair rules.
2. `Alignment`: load a JSON matrix; `project`, `score`, `stable?`; synthetic
   rotation, unequal dimensions, fewer-than-`k` pairs.
3. `Latent` and `LatentCard`: vector ref, rank, residual, anchors; no raw
   vector in the card; hash-pinned.
4. Ledger artifacts: `views.json`, `pairs.json`, `alignment.json`,
   `latent.json`, `latent_card.md`, `nuisance_probe.json`.
5. Receipt fields: `alignment_id`, `residual`, `rank`, `spectral_gap`,
   `view_kind`, `nuisance_delta`, `latent_sha`.
6. `d1` pair validator: reuse the `judge` role; no new role.
7. Fold alignment checks into `provenance` and `calibration`; keep the
   14-gate order.
8. `bench/swarm/latent_cases.json` + runner arms + metrics.

Acceptance matches PRD §17.2.

### 17.2 J1 — trained heads (only on J0 GO)

1. `bench/latent/views.py`: 2 global + 6 local views; 50–100% / 15–50% spans;
   15% mask; nuisance tags; deterministic seeds.
2. `bench/latent/fit.py`: LeJEPA/SIGReg, λ = .02, batch 256, gradient
   clipping, three seeds; collapse detection (effective rank, loss).
3. Export `config/alignments/*.json` and the head hash.
4. Ruby loads the metadata; the forward pass stays in the Python sidecar, not
   the kernel.
5. Promote `alignment` to a gate (15 gates, after `provenance`) and add the
   decline reasons only when the checks ship.
6. Run `team-latent-j1` against J0 and `team-full`; GO or NO-GO.

### 17.3 J2 — latent planner (research)

Synthetic dynamics with known actions, then a two-step retrieval task. Compare
against greedy at equal calls. Stop if either fails. Do not touch production.

### 17.4 Tests

| test | what it proves |
|---|---|
| `test/swarm_view_test.rb` | same state/different rendering is good; same bytes or same nuisance is bad; missing anchor is invalid |
| `test/swarm_alignment_test.rb` | a synthetic rotation is recovered; residual and gap are reported; unequal dims work; `< k` pairs is underdetermined |
| `test/swarm_latent_test.rb` | the card keeps anchors; the vector is hashed, not printed; rank/residual are present |
| `test/swarm_alignment_gate_test.rb` | the broker declines `alignment_unstable`; the guard flags a bad pair; a stable pair passes |
| `test/swarm_nuisance_probe_test.rb` | a font/paraphrase change does not change the answer; a scene change does |
| `test/swarm_latent_bench_test.rb` | the 8 cases run with fake models; no network; no tmp |

All are fake-driven; no live provider calls, GPU or network.

### 17.5 Commits

| # | commit | contents |
|---|---|---|
| J0a | `swarm: add view and alignment contracts` | `View`, `ViewSet`, `Alignment`, tests, fixtures |
| J0b | `swarm: add latent card and ledger artifacts` | `Latent`, `LatentCard`, ledger, receipts |
| J0c | `swarm: fold alignment checks into provenance and calibration` | broker/guard, staged behind J0 |
| J0d | `bench: add the 8-case swarm-latent suite` | cases, arms, metrics |
| J1a | `bench: add good-view fitting scripts and heads` | only on GO |
| J1b | `swarm: promote the alignment gate` | only on GO |

Do not commit `discovery.md` or `docs/2609.20804v1.pdf`.

### 17.6 Stop rules

- `bad-view-2x` ≥ `good-view-2x`: stop; fix the view contract.
- `same-model-3x` matches the latent arm: stop; do not ship.
- `no-rotation` or `random-rotation` matches: stop; fix the metric.
- Alignment improves but task pass does not: keep J0 as an index; no J1.
- The `q` sweep is flat: stop; the view contract is not doing the work.
- A negative result is published; do not add calls or a bigger model to
  rescue it.
