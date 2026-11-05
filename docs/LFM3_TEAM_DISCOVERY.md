# Discovery — the LFM3 team

**Status:** discovery · **Date:** 2026-11-01
**Inputs:** the [memdoor `team-solve` workflow](https://github.com/guregodevo/memdoor/tree/main/examples/workflows/team-solve)
and the [complete LFM3 collection](https://huggingface.co/collections/LiquidAI/lfm3).
**Companions:** `docs/SMALL_MODEL_HARNESS_PRD.md`, `docs/SMALL_MODEL_HARNESS_PLAN.md`.
**Scope:** a new team design, the contract changes it needs, and a benchmark
that can prove or disprove the claim. No implementation in this note.

---

## TL;DR

The previous cycle treated LFM3-1.7B as the whole swarm and tried to make
specialists out of prompts. The collection offers something better: **seven
different checkpoints with genuinely different jobs**. The discovery is that
the team should be built around that division of labour, not around more
calls to the text model:

- **`d1-2B` / `d1-Omni-2B` own calibrated decisions** — triage, routing,
  proposal selection, claim support, audio routing. They answer in one
  forward pass, return typed probabilities, and are not chat models.
- **`LFM3-VL-2B`, `LFM3-Audio-2B`, `LFM3-Omni-2B` own perception** — images,
  video, documents, screens, speech, sound events and joint audio-video.
- **`LFM3-1.7B` owns text generation** — proposals, grounded answers, claim
  audits, bounded repair and concise rewriting. It is the only model allowed
  to write prose, and it is supervised at every hop.
- **Ruby owns the control plane** — decomposition, identity assignment,
  budgets, checkpoints, the authoritative verifier, one repair round, and
  escalation. The model never owns the plan.
- **`LFM3-1.7B-Base` is the adapter substrate**, not a runtime role. Role
  LoRAs are the only honest way to make same-base text roles truly
  specialized; until they exist, text roles are profiles and the benchmark
  must say so.

The shape is:

```
triage (d1) → plan (Ruby) → perceive (VL/Audio/Omni) → ideate A‖B (1.7B)
→ judge (d1) → answer (1.7B) → test (Ruby) → review (d1 + Ruby)
→ repair (1.7B, once) → verify (Ruby) → answer (pass) / escalate (fail)
```

The memdoor `team-solve` pattern supplies the loop: fresh contexts, a disk
ledger, independent proposals, a non-blocking test capture, a manager review,
at most one repair round, and a final authoritative verify. The LFM3 suite
supplies the missing capability breadth. The combination is not "a big model
in a trench coat"; it is a **scoped, auditable team that can match a big model
on evidence-grounded, modality-specific work and declines the rest**.

The main contract finding: **the current swarm layer is text-only by
construction.** `Manifest` hardcodes `LiquidAI/LFM3-1.7B`, `Identity::ROLES`
has no perception/triage roles, `Capacity::SCHEMAS` has no plan/proposal/
perception schema, and `Checkpoint::GATES` cannot express modality,
provenance or calibration. The team cannot be built without extending those
allow-lists first.

## Findings at a glance

1. **The suite is a division of labour, not a bigger prompt.** Each checkpoint
   has a job the others are explicitly not recommended for.
2. **`d1` is the missing decision layer.** Calibrated, typed, one-pass
   decisions are a better fit for routing, selection and claim support than a
   1.7B model's verbal confidence.
3. **Perception is not reasoning.** VL, Audio and Omni produce evidence;
   they must not produce conclusions. Omni is explicitly non-reasoning.
4. **The contract layer is text-only.** `ModelFamily` is the first change;
   without it, a vision or audio manifest is either impossible or a lie.
5. **The full suite is a catalog, not a resident set.** Per-shape loading and
   cold/warm accounting are part of the design, not an optimization.
6. **Memdoor's manager risk is fixed by splitting facts from scores.** Ruby
   owns the captured status and the repair instructions; `d1` owns the
   calibrated semantic scores; a counterexample must be executable.
7. **The honest claim is scoped reliability, not frontier parity.** The team
   should win on evidence-grounded, modality-specific work and decline the
   rest.

---

## 1. Method: applying `team-solve` to the discovery itself

The request was to use memdoor's `team-solve` pattern. The pattern was applied
to the design question, not just described:

| memdoor step | what it did here |
|---|---|
| `plan` | Fixed the question, the acceptance criteria, and the evidence to read: the seven model cards, the eight step YAMLs, and the existing contract layer. |
| `ideate-a` | **Capability-first design:** assign one checkpoint per modality and let the pipeline follow the data. |
| `ideate-b` | **Contract-first design:** keep the role/contract layer and treat models as interchangeable adapters behind it. |
| `solve` | **Hybrid:** contract-first control plane, capability-first model assignments, memdoor loop. |
| `test` | Checked every claim against the model cards and the existing allow-lists; checked the loop against memdoor's constraints (fresh contexts, disk ledger, deterministic verify, one repair). |
| `review` | Found four gaps: text-only manifests, missing roles/schemas/gates, no calibration policy, no model-residency story. |
| `repair` | Added the `ModelFamily` layer, the new gates, the calibration bands, and the residency/latency accounting. |
| `verify` | The checklist in §13. |

The two proposals are recorded in §3 because their disagreement is the useful
part: it shows why a pure pipeline and a pure contract layer both fail.

---

## 2. Evidence

### 2.1 What each LFM3 checkpoint can and cannot do

| checkpoint | size | context | input → output | what it is for | what it must not be asked to do |
|---|---:|---:|---|---|---|
| **LFM3-1.7B** | 1.73B | 256K | text → text | local agents, tool calling, structured output, grounded QA, 16 languages, thinking | agentic coding, complex multi-step reasoning, planning a whole task |
| **LFM3-1.7B-Base** | 1.73B | 256K | text → text | pre-trained substrate (22T tokens) for CPT/SFT/LoRA | chat, tool use, production roles without an adapter |
| **LFM3-VL-2B** | 1.92B | 128K | text + image + video → text | documents, charts, screens, object location, spatial reasoning, video (2 fps, 4–768 frames) | coding, multi-turn chat, complex reasoning |
| **LFM3-Audio-2B** | 2B | 32K | text/audio → text/speech | streaming ASR, 18-language speech translation/TTS, audio understanding, spoken tool calls | long-context reasoning; voice chat is currently English-only |
| **LFM3-Omni-2B** | 2.17B | 32K | text/image/video/audio → text/speech | one-pass joint audio-video understanding (2 fps, 4–384 frames); replaces ASR + VLM + LLM + TTS | reasoning, planning, critique; `enable_thinking` is unsupported |
| **d1-2B** | 1.92B | 128K | state + typed questions → calibrated typed answers | triage, routing, classification, extraction, judging, reranking, boxes, counts | chat, prose, long free-form answers; reliable only to ~64K state |
| **d1-Omni-2B** | 2.17B | 128K | state + audio + typed questions → calibrated typed answers | spoken-request routing, sound events, audio triage | transcription, speech output, chat; weaker than d1-2B on text; long spoken passages lose accuracy |

The decision models are also the cheapest calls in the suite: `d1-2B` reports
5.7 ms per decision on an H100 (3.8 ms on an MI325X); `d1-Omni-2B` reports
5.8/3.7 ms, or 12.4/8.2 ms with a 10-second clip. That makes calibrated
routing and judging affordable at every hop, not just at the start.

Three facts drive the design:

1. **`d1` is a different kind of computation.** It does not generate tokens;
   it reads answers from one forward pass and returns probabilities. That makes
   it the right owner for decisions that a 1.7B model should not make verbally.
2. **The multimodal models are perception, not reasoners.** VL can read a
   chart but is not recommended for complex reasoning; Omni is explicitly
   non-reasoning; Audio is a 32K-context specialist. They produce evidence,
   not conclusions.
3. **The text model is the only prose engine, and it is the weakest at
   planning.** It must receive one micro-task at a time, with a schema and a
   checkpoint, never a plan or a transcript.

The earlier PRD resolved "vision capability" as **supervision**, because
LFM3-1.7B is text-only. With `LFM3-VL-2B`, vision becomes a **perception
role**, and supervision remains the control plane. Both are needed:
perception without supervision is unverified; supervision without perception
is blind.

### 2.2 What `team-solve` contributes

The workflow is a ledger-based team with fresh contexts:

```
plan → (ideate-a || ideate-b) → solve → test → review → repair → verify
```

- The planner writes `plan.md` and initializes `notes.md` with unique anchors.
- Two ideators append independent proposals to distinct anchors; they never
  overwrite the shared file.
- The solver selects and justifies an approach, then writes the artifact.
- `test` captures the strict runner's status **without blocking** the manager.
- The manager inspects the captured results, writes `review.md`, and appends
  concrete repair instructions; it does not edit the artifact.
- One fresh repair worker gets one round. No second round, no human gate.
- `verify` reruns all samples and is the only authority on success.
- Every agent reads state from disk; chat context is not shared.
- The notes warn that a manager can invent a wrong counterexample. Keep the
  last artifact that passed samples and validate counterexamples with brute
  force.

That is exactly the supervision shape the 1.7B tier needs. What it lacks is a
way to see, hear, or make a calibrated decision. The LFM3 suite fills those
gaps; the contract layer makes them enforceable.

Two deliberate deviations from memdoor:

- **The planner is Ruby, not a model.** Memdoor's planner is an agent; the
  LFM3-1.7B card explicitly does not recommend complex multi-step planning.
  The deterministic planner writes the DAG and the acceptance checks; the
  model only ever sees one micro-step.
- **The manager's judgment is split.** Ruby owns the facts, the captured test
  status and the repair instructions; `d1` owns the calibrated semantic
  scores. This directly addresses memdoor's warning that a manager can invent
  a wrong counterexample: a counterexample is not accepted until an executable
  or brute-force check confirms it.

---

## 3. Two designs and why the hybrid wins

### 3.1 Proposal A — capability-first pipeline

Assign one checkpoint per modality and chain them:

```
triage (d1) → vision (VL) → audio (Audio) → omni (Omni)
            → answer (1.7B) → verify (Ruby)
```

**Strengths:** obvious, uses every checkpoint, each model does what its card
recommends, easy to explain.

**Failure:** the pipeline is data-driven, not task-driven. A text-only task
still pays for perception roles; a decision task still pays for prose; a
missing modality becomes a hard failure instead of a route. It also has no
independent proposals, no claim audit, and no bounded repair, so it cannot
approach big-model reliability on contested answers.

### 3.2 Proposal B — contract-first roles

Keep the existing role layer and treat every checkpoint as an interchangeable
adapter behind the same `IDENTITY`/`CAPACITIES` contract. The conductor
selects roles from the task profile; models are implementation details.

**Strengths:** preserves the Phase 1/2 work, keeps identity/capacity
enforcement, makes the benchmark model-agnostic, and allows a role to be
swapped without changing the loop.

**Failure:** it treats "answerer" as one role and hides the fact that vision,
audio and decision are *different kinds of work*. A single `answer.v1` schema
cannot carry a box, a transcript with timestamps, or a calibrated probability.
It also makes it too easy to keep calling the same 1.7B model and call it a
team.

### 3.3 Selected design — contract-first control plane, capability-first roster

The hybrid keeps the contract layer as the source of truth and gives each
capability its own contracted role with its own schema, permissions and
failure semantics:

- the **conductor and planner are deterministic**;
- **d1 owns typed decisions** (triage, selection, support);
- **VL/Audio/Omni own perception** and emit `perception.v1`;
- **1.7B owns text artifacts** and emits `proposal.v1`, `answer.v1` or
  `critique.v1`;
- **Ruby owns acceptance** and emits `violations.v1`;
- **escalation is external and explicit**.

This is the only combination that uses the whole suite without pretending the
suite is one generalist.

---

## 4. The team

### 4.1 Roster

Control plane (deterministic, no model call):

| role | identity | model | can | must decline when | schema |
|---|---|---|---|---|---|
| **Conductor** | `conductor.router@1.0.0` | Ruby | route, budget, select shape, enforce contract, escalate, decline | no shape fits, budget exhausted, task outside all manifests | `decision.v1` |
| **Planner** | `planner.microstep@1.0.0` | Ruby | decompose, choose shape, define acceptance, set anchors, budget | task is out of scope, required modality absent, plan cannot be verified | `plan.v1` |
| **Reviewer** | `reviewer.manager@1.0.0` | Ruby | inspect captured test status, write review, issue repair instructions, decline | test status missing/unreadable, counterexample unvalidated | `review.v1` |
| **Verifier** | `verifier.mechanical@1.0.0` | Ruby | citations, anchors, numbers, schema, modality, provenance, truncation, artifact, progress, calibration thresholds | a check cannot be evaluated, evidence is malformed | `violations.v1` |

Decision plane (calibrated, one forward pass):

| role | identity | model | can | must decline when | schema |
|---|---|---|---|---|---|
| **Triage** | `triage.d1@1.0.0` | `d1-2B` | detect modality, classify intent, score scope/risk/sufficiency, recommend shape, decline | request is unsafe, out of family, or no shape is viable | `verdict.v1` |
| **Audio triage** | `triage.audio@1.0.0` | `d1-Omni-2B` | classify spoken request, detect sound events, route audio task | audio is unintelligible, out of family, or no audio role fits | `verdict.v1` |
| **Judge** | `judge.d1@1.0.0` | `d1-2B` | score proposal support/coverage/risk, choose/merge/neither, score claim support/contradiction, sufficiency | evidence is insufficient to score, or the question is outside its criteria | `verdict.v1` |
| **AV judge** | `judge.omni@1.0.0` | `d1-Omni-2B` | score audio/visual agreement, detect contradiction, choose the evidence source | media missing or unintelligible, or the task is text-only | `verdict.v1` |

Perception plane (evidence only):

| role | identity | model | can | must decline when | schema |
|---|---|---|---|---|---|
| **Vision** | `perceiver.vision@1.0.0` | `LFM3-VL-2B` | read image/video/document/chart/screen, locate objects, describe scene, cite page/box/time | no image/video, media unreadable, task asks for judgment or prose | `perception.v1` |
| **Audio** | `perceiver.audio@1.0.0` | `LFM3-Audio-2B` | transcribe, translate speech, detect sound events, describe audio | no audio, audio unreadable, task asks for a decision or prose answer | `perception.v1` |
| **Omni** | `perceiver.omni@1.0.0` | `LFM3-Omni-2B` | read audio-video jointly, align speech to frames, describe joint scene | media needs reasoning, or the task is text-only | `perception.v1` |

Text plane (prose only, fresh context per call):

| role | identity | model | can | must decline when | schema |
|---|---|---|---|---|---|
| **Ideator A** | `ideator.direct@1.0.0` | `LFM3-1.7B` | propose the most direct approach, cite evidence, state invariant and edge cases | evidence missing, task is a decision, or asked to critique | `proposal.v1` |
| **Ideator B** | `ideator.alternative@1.0.0` | `LFM3-1.7B` | propose a different technique family, compare tradeoffs, state disconfirming evidence | evidence missing, no genuinely different family, or asked to answer | `proposal.v1` |
| **Answerer** | `answerer.grounded@1.0.0` | `LFM3-1.7B` | select/merge proposals, answer with citations, abstain, decline | evidence missing/conflicting, requested value absent, out of capacity | `answer.v1` |
| **Critic** | `critic.claims@1.0.0` | `LFM3-1.7B` | audit claims against evidence, list unsupported/contradicted claims | evidence insufficient, task asks for a rewrite, out of capacity | `critique.v1` |
| **Repairer** | `repairer.bounded@1.0.0` | `LFM3-1.7B` | remove/replace unsupported claims, preserve citations, decline | repair would add facts, change evidence, or require a second round | `answer.v1` |
| **Finalizer** | `finalizer.concise@1.0.0` | `LFM3-1.7B` | rewrite concisely, preserve citations, decline | rewrite would add facts, corrections conflict, evidence missing | `answer.v1` |

Escalation (external):

| role | identity | model | can | must decline when | schema |
|---|---|---|---|---|---|
| **Escalation** | `escalation.frontier@1.0.0` | external/human | answer, reason, human review, decline | no endpoint configured, policy forbids it | `answer.v1` |

Every row also declares a non-empty `cannot` list, disjoint from `can`, in
its manifest; the tables show the positive allow-list and the refusal trigger
to stay readable. A capability outside `can` is an overreach even when it is
not named in `cannot`.

The existing `scout.retriever` is retained for the retrieval suite; it is not
part of the precomputed-evidence pilot.

### 4.1.1 Responsibility boundaries

- Only `answerer`, `repairer` and `finalizer` may emit `answer.v1`. `critic`
  may not rewrite; `ideator` may not produce the final answer.
- Only `perceiver.*` may emit `perception.v1`; they may not answer or judge.
- Only `triage` and `judge` may emit `verdict.v1`; they may not write prose.
- Only `verifier` may emit `violations.v1`; it may not answer or escalate.
- Only `conductor` may route or escalate. A model may recommend a hop; it
  never chooses one.
- Only `reviewer` may issue repair instructions; it may not edit the answer.
- Only `escalation` may answer outside local capacity; it is never a silent
  fallback.

The roster is a catalog, not a resident set. A shape loads only the roles it
needs. See §7.4.

### 4.2 Team shapes

The conductor selects one shape from triage, the task profile and the
registry. The model never selects its own shape.

| shape | when | steps | model calls |
|---|---|---|---|
| `decide` | classification, extraction, routing, box, count, date, score; no prose needed | triage (typed answer) → (judge) → verifier | 1–2 d1 |
| `answer-lite` | simple grounded QA, low risk, text only | plan → answerer → test → review (judge + reviewer) → (repair) → verify | 2–3 text + 1 d1 |
| `answer-full` | contested, ambiguous, multi-step, high risk | plan → ideate A‖B → judge/select → answerer → test → critic → review (judge + reviewer) → (repair) → verify → (finalize) | 5–7 text + 2 d1 |
| `see` | image, video, document, chart, screen | triage → vision → (answer-lite or answer-full) | 1 VL + text shape |
| `hear` | speech, sound, call, spoken request | audio triage → audio → (answer-lite or decide) | 1 Audio + text shape |
| `watch` | video with soundtrack, joint AV | triage → omni (or vision ‖ audio) → AV judge → (answer-lite or answer-full) | 1–2 perception + 1 d1 + text shape |
| `escalate` | agentic coding, long-horizon plan, unsafe, high-stakes, no evidence | triage → decline/escalate → receipt | 0 local |

`answer-full` is the memdoor parity shape. `answer-lite` is the default for
text. `decide` is the cheap path that a big model often overpays for.
`see`/`hear`/`watch` prepend perception and then reuse the text shape.

---

## 5. The loop

### 5.1 Memdoor parity, with perception and calibration

```
intake
  d1 triage: modality, intent, scope, risk, evidence sufficiency, shape
  conductor validates triage against registry, budgets and policy
  if out of scope / unsafe / no shape -> decline or escalate, receipt, stop

plan (Ruby)
  write task.md verbatim; index evidence/perception by hash
  write plan.md:
    - shape and micro-step DAG
    - required capabilities per step
    - acceptance checks (mechanical + d1 questions + thresholds)
    - candidate technique families for A/B
    - call, wall and token budgets
    - unique anchors for proposal-a, proposal-b, review, repair
    - fresh run id; no prior-run artifact may be reused
  verify anchors occur exactly once; plan is complete

perceive (only if the shape needs it; independent calls may run in parallel)
  vision: image/video/document/chart/screen -> perception.v1
  audio:  audio -> perception.v1 (transcript, segments, language, events)
  omni:   audio-video -> perception.v1 (aligned speech/frame anchors)
  each call is one modality, one artifact, one schema
  provenance gate: every anchor resolves to a real page/box/time/frame
  d1 judge: is perception sufficient? which required fields are missing?
  AV judge: do audio and visual evidence agree? if not, flag the conflict
            and do not let one modality silently override the other
  if insufficient -> one targeted re-perception, or decline missing_evidence

ideate A || B (fresh contexts, parallel)
  A: most direct approach, invariant, citations, edge cases
  B: different technique family, tradeoffs vs A, disconfirming evidence
  both read task.md, plan.md and validated evidence only
  append to distinct anchors; never overwrite notes.md
  conductor checks both present, markers unique, proposals differ
  if identical -> record proposal_collapse; do not count as two

select (d1 judge)
  score each proposal: support (noul), coverage (score), risk (score)
  choose A/B/merge/neither (choice)
  thresholds: choose if P(support) >= 0.80 and margin >= 0.15;
              merge if both >= 0.70 and complementary;
              neither -> answerer must synthesize or decline
  record every score and threshold in calibration.json

solve (answerer, fresh)
  receives task, validated evidence/perception, the selected proposal(s)
  and the d1 rationale; writes answer.v1 with citations
  does not receive the transcript, the critic notes or the raw proposals

test (deterministic, non-blocking)
  run every mechanical check; write test-status.txt + test-output.log
  never abort the workflow on failure; the manager must see the result

review (d1 judge + reviewer.manager)
  d1: per-claim support (noul), contradiction (noul), answer sufficiency (noul)
      batch claims into judge-sized sets (default 16); record the batch size
  reviewer.manager (Ruby): write review.md and concrete repair instructions
  reviewer may not edit the answer; a counterexample must be validated
  if test passes and support is high -> no repair, go to verify
  if not -> exactly one repair round

repair (one round, fresh)
  receives task, answer, violations, review and evidence
  may only remove/replace unsupported claims and preserve citations
  may not add facts, change evidence, change tests, or start another round
  writes answer.v1 and a repair note

verify (authoritative)
  rerun every mechanical check and d1 support on the repaired answer
  fail -> decline or escalate; keep the last artifact that passed
  never accept a regression to make the run green

finalize (optional)
  concise rewrite preserving citations; verify again
  if it declines, the verified answer stands

receipt
  identity, capacities, decision, decline, checkpoints, role_receipts,
  plan, notes, perception, proposals, review, test logs, calibration
```

The loop is deliberately linear with at most two fan-outs (perception and
proposals) and one conditional repair. That is enough to capture memdoor's
gains without giving the 1.7B model a planner it cannot carry.

### 5.2 Fresh-context rules

Every role call receives exactly:

1. its assigned `IDENTITY` and `CAPACITIES` block;
2. one instruction for one micro-task;
3. the validated artifact(s) and anchors it needs;
4. the output schema and budget.

It never receives the transcript, another role's raw output, the full plan, or
a "solve the whole task" prompt. This is the main defence against a small
model's context anchoring and against same-model roles sharing blind spots.

### 5.3 Parallel-writer rules

- `plan.md` reserves unique literal anchors before any parallel call.
- Ideators patch-insert before their anchor; they never rewrite `notes.md`.
- If the ledger changed, re-read and retry a minimal insertion.
- The conductor verifies each anchor occurs exactly once before and after.
- A missing anchor is a `contract_invalid` stop, not a silent overwrite.

---

## 6. Checkpoints and gates

### 6.1 Gate order

The current layer has eleven gates. The team needs three more:

```
call → envelope → identity → capacity → decision → body → schema
     → modality → provenance → verifier → calibration → progress
     → budget → route
```

| gate | owner | what it proves | failure status |
|---|---|---|---|
| `call` | adapter | the call completed; not truncated, empty-stop or infra | `:infra`, `:truncated`, `:empty_stop` |
| `envelope` | `ContractGuard` | all four blocks parse | `:unverified` |
| `identity` | `ContractGuard` | echoed identity equals the assigned manifest | `:unverified` |
| `capacity` | `ContractGuard` + broker | required capabilities present; no overreach | `:unverified`, `:declined` |
| `decision` | `Decision` | status/reason/hop are valid | `:unverified` |
| `body` | `ContractGuard` | accept has a body; decline/escalate has none | `:unverified` |
| `schema` | `ContractGuard` | output schema is the manifest's schema | `:unverified` |
| `modality` | `ContractGuard` | artifact modality matches the model family and role | `:unverified` |
| `provenance` | verifier | every anchor resolves to a real input range | `:unverified`, `:declined` |
| `verifier` | `Guards` | citations, numbers, artifact, truncation, injection | `:repaired`, `:declined` |
| `calibration` | judge + conductor | d1 score is inside the accept/repair/decline band | `:declined`, `:unverified` |
| `progress` | conductor | the body SHA differs from the previous attempt; run id is fresh | `:no_progress` |
| `budget` | broker | calls and wall-clock budget remain | `:declined`, `:infra` |
| `route` | conductor | next hop is in the shape and registry; no same-role retry | `:declined`, `:escalated` |

Every gate is present on every checkpoint; a non-applicable gate is `:skip`,
never absent. A failed gate is a hard stop: the raw artifact never reaches the
next role.

### 6.1.1 Structured models and the envelope

The four-block envelope is a text contract. `d1` is not a chat model and
cannot emit it; the perception models can emit text but should not be trusted
to stamp their own identity. The adapter therefore has two modes:

- **echo mode** (text roles): the model emits `IDENTITY` / `CAPACITIES` /
  `DECISION` / `BODY`; `ContractGuard` compares the echo to the manifest.
- **stamp mode** (`d1`, perception): the adapter writes the envelope from the
  assigned manifest and the typed artifact. The model never chooses its
  identity. The `identity` gate is `:skip` with `identity_source: adapter`,
  and the receipt records it; `schema`, `modality`, `provenance` and
  `calibration` carry the enforcement.

A decline from a structured role writes an empty envelope body and a
`verdict.json` or `perception.json` artifact; the calibration/provenance gate
reads the artifact. The envelope's `message` stays one sentence and carries no
facts. This keeps the "identity is assigned, not chosen" rule true even when
the model has no text channel to echo it.

### 6.2 Why the new gates are not optional

- **`modality`** stops a text role from claiming it "saw" an image, and stops
  a vision role from emitting a prose answer. Without it, the suite's
  separation of duties is only a prompt convention.
- **`provenance`** stops invented page numbers, timestamps, boxes and frame
  indices. A perception artifact without a resolvable anchor is not evidence.
- **`calibration`** stops a confident-sounding answer from passing when the
  calibrated judge says the support is in the repair or decline band. It also
  makes the thresholds auditable instead of implicit.

### 6.3 Calibration bands

The judge returns probabilities; the conductor applies explicit bands:

| decision | band |
|---|---|
| accept / no repair | `P(support) >= 0.80` and `P(contradiction) <= 0.10` |
| repair | `0.30 <= P(support) < 0.80` or `0.10 < P(contradiction) < 0.50` |
| decline / escalate | `P(support) < 0.30` or `P(contradiction) >= 0.50` |
| abstain | evidence readable but the requested value is absent |

The bands are configuration, not model output. They are recorded per task
family and per benchmark seed. A calibration set is required before the
bands are trusted; otherwise the judge is a suggestion, not a gate. The
calibration set must be separate from the 24-case pilot, or the ECE is
in-sample and meaningless.

---

## 7. What must change in the contract layer

The current layer is a good text-only contract. It cannot express the team.

### 7.1 Roles

`Identity::ROLES` currently has `conductor scout answerer critic verifier
finalizer escalation generalist`. Add:

- `planner`, `reviewer` (deterministic)
- `triage`, `judge` (d1)
- `vision`, `audio`, `omni` (VL/Audio/Omni)
- `ideator`, `repairer` (text)

`Checkpoint` validates roles against the same list, so this is one allow-list
change, not two. The `agent_id` is the public name; the `role` field is the
allow-list key. For example, `perceiver.audio@1.0.0` has role `audio`, and
`perceiver.omni@1.0.0` has role `omni`.

### 7.2 Model family

`Manifest` hardcodes `BASE_MODEL = 'LiquidAI/LFM3-1.7B'` for every
non-deterministic, non-escalation role. Replace it with a `ModelFamily` table:

| role family | allowed base models |
|---|---|
| `conductor`, `planner`, `reviewer`, `verifier` | `ruby` |
| `escalation` | `external` |
| `triage`, `judge` | `LiquidAI/d1-2B`, `LiquidAI/d1-Omni-2B` |
| `vision` | `LiquidAI/LFM3-VL-2B` |
| `audio` | `LiquidAI/LFM3-Audio-2B` |
| `omni` | `LiquidAI/LFM3-Omni-2B` |
| `ideator`, `answerer`, `critic`, `repairer`, `finalizer`, `scout` | `LiquidAI/LFM3-1.7B`; `LiquidAI/LFM3-1.7B-Base` only with a non-nil `adapter_sha256` |

`ModelFamily` also carries the static facts the conductor needs: modalities,
context length, output modes and known limits. `Capacity#max_input_tokens`
must be `<=` the family context; a manifest that exceeds it is invalid.

This is the key contract change. Without it, a "vision" manifest is either
impossible or a lie.

### 7.3 Schemas, reasons and hops

`Capacity::SCHEMAS` gains:

- `plan.v1` — shape, steps, required capabilities, acceptance checks, anchors,
  budgets;
- `proposal.v1` — approach, invariant, citations, complexity/risk, edge cases,
  disconfirming evidence;
- `perception.v1` — modality, source hash, anchors, text/tables/objects/events,
  language, confidence, unknowns;
- `verdict.v1` — named typed answers with probabilities, thresholds/bands and
  an optional rationale; this is how `d1` reports a decision without pretending
  to be a chat model;
- `review.v1` — test status, claim findings, repair instructions, verdict.

Keep `answer.v1`, `critique.v1`, `evidence.v1`, `decision.v1`,
`violations.v1`. `decision.v1` remains the control-plane accept/decline/
escalate envelope; `verdict.v1` is the calibrated evidence behind it.

`Decision::REASONS` gains:

`out_of_modality`, `needs_perception`, `needs_vision`, `needs_audio`,
`needs_omni`, `perception_insufficient`, `low_support`, `proposal_collapse`,
`repair_exhausted`, `unsafe_request`, `out_of_scope`, `ambiguous_request`.

`Decision::HOPS` gains:

`planner`, `reviewer`, `triage`, `judge`, `vision`, `audio`, `omni`,
`ideator`, `repairer`.

Two smaller allow-lists move with them:

- `Manifest::DETERMINISTIC_ROLES` gains `planner` and `reviewer`, so
  `planner.microstep` and `reviewer.manager` must use `base_model: "ruby"`
  and `max_output_tokens: 0`.
- `CapacityBroker` rule order becomes:
  `nil manifest -> no_route`; calls budget; wall budget; missing modality;
  missing evidence; missing capabilities; calibration band; accept. The
  modality check is before evidence so a text role never receives an image
  packet and a vision role never receives a text-only task.
- `ContractGuard` gains `modality_mismatch`, `provenance_missing`,
  `calibration_low` and `perception_shape` so the new gates are enforceable
  rather than advisory.

### 7.4 Residency and cost

The complete suite is a catalog, not a resident set. At 4-bit, the seven
checkpoints are roughly 8–10 GB together; a 16 GB laptop can hold them with
lazy loading, a phone cannot. The conductor must:

- load only the models a shape needs;
- keep an LRU cache and report cold vs warm latency separately;
- never mix cold and warm in one average;
- report per-shape peak memory, not a fictional "full suite on device" number.

This is also a design constraint: `answer-lite` and `decide` are cheap and
can run on a phone; `watch` is a laptop/desktop shape.

### 7.5 Ledger and receipts

`WorkLedger::FILES` gains:

`triage`, `plan`, `perception`, `notes`, `proposals`, `review`, `test_status`,
`test_output`, `final_test_output`, `calibration`.

A long transcript or a multi-page document can exceed the ledger's 1 MB
artifact limit. The adapter must chunk by page/time and write a compact
evidence index plus chunk files, or decline; it must never silently truncate
an artifact that still carries anchors.

`RunReceipt` gains:

`model_family`, `modalities`, `calibration` (scores + bands), `divergence`
(proposal A/B), `repair_round` (0 or 1), `cold`/`warm`.

### 7.6 Runtime seams

- `Runes::LLM::D1Adapter` — `system_one(state, questions, media:)`, typed
  answers, no sampling parameters, no token generation.
- `Runes::LLM::VisionAdapter` — image/video/document input, text output.
- `Runes::LLM::AudioAdapter` — audio/text input, text output in v0; speech
  output is a later finalizer mode, not a perception role.
- `Runes::LLM::OmniAdapter` — joint audio-video input, text output in v0;
  speech output is the same later mode.
- `Runes::Orchestration::TeamPlan` / `Shape` — the DAG and budgets.
- `Runes::Orchestration::Conductor` — shape selection, fan-out, two-phase
  verify, one repair, receipts.

The adapters are command/server seams with fakes in the default suite. No live
model call in `rake test`. All JSON goes through `Runes::Json`; kernel code
must not call `::JSON` directly. The broker's accept remains a control-plane
decision with body `authorized`; it is not a model answer and must never be
counted as one.

Each text profile pins its sampler and thinking mode: ideation uses the
higher-diversity setting (memdoor used 0.3–0.4), answer/critic/repair use the
low-temperature setting (0.1–0.2), and the math/STEM sampler is used only for
math cases and labelled. `enable_thinking` is off for envelope/schema calls
and on only where reasoning helps; the seed (or `null`) and the mode are in
the receipt.

---

## 8. How this approaches big-model power

Big-model power is not one number. It decomposes into breadth, reasoning,
calibration and reliability. The team attacks each one differently.

| big-model advantage | team lever | honest limit |
|---|---|---|
| Sees images, video, audio | VL/Audio/Omni perception roles | Perception is extraction, not reasoning; anchors must be verified. |
| Knows the world | scout + retrieval + citations | The 1.7B weights are not a knowledge base; v0 uses precomputed evidence. |
| Knows when it is unsure | d1 calibrated probabilities + explicit bands | d1 is only calibrated on its training distribution; needs a local calibration set. |
| Follows a complex plan | deterministic planner + micro-steps + checkpoints | The team does not do open-ended long-horizon planning; it declines or escalates. |
| Produces a coherent long answer | two independent proposals + judge + answerer + critic + bounded repair | Text roles share the 1.7B base until adapters exist; the benchmark must report that. |
| Integrates modalities in one context | Omni for joint AV, VL+Audio for reasoning | Omni is non-reasoning and 32K; use it for extraction, not judgment. |
| Rarely fabricates | deterministic verifier + provenance + claim support + one repair | No verifier can prove truth; it proves groundedness and contract compliance. |
| Handles anything | explicit out-of-scope decline + escalation | The team is deliberately narrower than a frontier model. |

The claim to test is therefore not "1.7B + friends = frontier". It is:

> On scoped, evidence-grounded tasks, a contracted team drawn from the full
> LFM3 suite can match or beat a single local generalist and close a measurable
> part of the gap to a frontier model, while declining the tasks where it
> cannot compete.

That claim is falsifiable. The benchmark in §9 is designed to falsify it.

### 8.1 The levers, in order of expected value

1. **Calibrated decisions (d1).** Replacing verbal routing and verbal
   confidence with typed probabilities is the largest reliability gain per
   millisecond. It also removes a job the 1.7B model is bad at.
2. **Modality coverage (VL/Audio/Omni).** This is capability a text big model
   does not have without tools. It is the clearest "big-model-like" win.
3. **Deterministic verification.** The verifier, not the model, owns
   acceptance. This is the same lesson as the legacy Bonsai pilot: the code
   verifier was the only reliable lift.
4. **Independent proposals + calibrated selection.** Diversity helps only if
   the proposals actually differ and the selector is calibrated. Measure both.
5. **Bounded repair.** One round, fresh context, no new facts. It fixes
   correctable errors without turning the run into a loop.

Adapters (LoRA on Base) are a sixth lever, but they are gated: no adapter is
claimed as a win without a held-out role comparison. Retrieval/tool use
(the scout) is the seventh: it is how the team reaches knowledge that is not
in the 1.7B weights. v0 uses precomputed evidence; the retrieval suite is
where the scout is measured.

---

## 9. Benchmark

### 9.1 Cases (24-case pilot)

| family | cases | examples | primary checks |
|---|---:|---|---|
| text QA | 6 | grounded answer; absent value → abstain; conflicting evidence → decline; ambiguous question → clarify/decline | citations, numbers, decision, claim support |
| vision | 4 | chart value; invoice fields; screen button; object count/box | field accuracy, anchor validity, no invented text |
| audio | 4 | ASR transcript; French audio → French text; sound event; spoken request → intent | WER/field accuracy, language, segment anchors |
| audio-video | 2 | speech + visual referent; audio/visual contradiction | joint anchor, conflict detection |
| decision | 6 | intent, team routing, urgency score, extraction, moderation, rerank | typed answer, calibration, latency |
| out of scope | 2 | agentic coding; long-horizon plan | decline/escalate, no false answer |

Each case carries gold fields, gold anchors, expected decision and optional
`forbidden_roles`. The benchmark uses precomputed media and evidence; live
retrieval is a separate suite.

### 9.2 Arms

| arm | composition | purpose |
|---|---|---|
| `solo-1.7B` | one text call | text baseline |
| `solo-VL` | one VL call | vision baseline |
| `solo-Audio` | one Audio call | audio baseline |
| `solo-Omni` | one Omni call | AV baseline |
| `same-model-3x` | 1.7B answer → critic → repair | control; never the candidate |
| `d1-only` | triage → judge → verifier | decision baseline |
| `text-lite` | answerer + d1 judge + verifier | cheap text team |
| `text-full` | ideate A‖B → judge → answerer → critic → judge → repair | memdoor parity |
| `perception+text-lite` | VL/Audio/Omni → text-lite | modality lift |
| `team-full` | shape router + all roles | candidate |
| `frontier-1x` | external reference | gap measurement |
| `profile-only` vs `adapter` | text roles with/without LoRA | specialization honesty |

The legacy `Cumulative`, `BonsaiAdapter` and `bench/cumulative/` arms remain
**controls**, never candidates. They are useful precisely because they are the
same-model repetition the new team must beat.

### 9.3 Metrics

- **Task pass:** all checks pass, including expected decision.
- **Modality routing accuracy:** selected shape vs expected shape.
- **Perception fidelity:** field precision/recall, anchor validity, invented
  anchor rate, transcript WER where gold exists.
- **Proposal divergence:** fraction of A/B pairs with materially different
  approaches; unique-information gain of B over A.
- **Selection quality:** chosen proposal's pass rate vs best/worst available;
  judge calibration (ECE, Brier, AUC) on support and choice.
- **Claim support:** precision/recall of unsupported claims; false-accept rate.
- **Repair lift:** pass before/after; regression rate; repair-round usage.
- **Decline/escalation:** precision/recall, false-answer rate, over-decline
  rate on answerable cases.
- **Contract:** identity mismatch, capacity overreach, modality mismatch,
  provenance missing, unvalidated hops (must be 0), stale artifact reuse
  (must be 0).
- **Cost:** calls by model/role, tokens, wall time, cold vs warm, per-shape
  peak memory.
- **Gap closure:** `(team - baseline) / (frontier - baseline)` per family,
  with a confidence interval, where the baseline is the matching single-model
  arm (`solo-1.7B` for text, `solo-VL` for vision, `solo-Audio` for audio,
  `solo-Omni` for AV, `d1-only` for decisions). Comparing a multimodal team
  to a text-only baseline would inflate the lift. If the denominator is zero
  or negative, report `n/a`, never a fabricated percentage. Report text and
  multimodal separately; never pool them into one "big-model parity" number.

### 9.4 Go / no-go

**v0 harness gate**

- `bundle exec rake test` green; no live model calls in the default suite.
- Every injected identity, capacity, modality, provenance and calibration
  violation is caught.
- No accepted artifact without a passing checkpoint and a verifier pass.
- Unvalidated hops = 0; stale artifacts = 0.
- Every decline has a typed reason and a route.

**Pilot gate (24 cases, 1 seed)**

- `text-lite` >= `solo-1.7B` + 2 cases on the text subset, zero regressions on
  cases solo passed.
- `team-full` >= `text-lite` + 2 cases on the multimodal/decision subset.
- Decline recall = 100% on out-of-scope; false-answer rate = 0.
- Judge ECE <= 0.10 on the calibration set.
- Cost, warm, per shape: `decide` <= 0.5× solo, `answer-lite` <= 2×,
  `text-full` <= 4×, `team-full` <= 5×; per-shape memory reported. A single
  "3×" number would hide the fact that `team-full` is a bigger team.
- If there is no lift, publish the negative result. Do not add a fourth
  same-model call to rescue it.

**Product gate (24 cases, 3 seeds, follow-on only if pilot is GO)**

- Gap closure >= 25% on multimodal/decision; text gap closure reported
  honestly, even if small.
- Decline recall stays 100%; false-answer rate stays 0.
- Contract violations stay 0; unvalidated hops stay 0.
- Cost <= 5× solo warm for `team-full`; `decide` and `answer-lite` keep their
  pilot bounds; no claim of open-ended parity.

---

## 10. Failure modes and mitigations

| risk | mitigation |
|---|---|
| d1 is overconfident off-distribution. | Per-family calibration set, explicit bands, abstain band, never the sole acceptance for high-stakes tasks. |
| Triage and judge share `d1-2B` and may share calibration errors. | Different question sets and thresholds; the Ruby verifier owns acceptance; use `d1-Omni` or a 1.7B critic as a second judge for high-stakes cases. |
| VL invents text or numbers in a chart. | Require page/box anchors; cross-check critical values with a second VL pass or d1 extraction; deterministic numeric checks; mark `unverified` if no independent source. |
| ASR errors propagate. | Segment timestamps, language detection, d1-Omni confirmation of key entities, chunking; decline on unintelligible audio. |
| Omni is treated as a reasoner. | Omni emits `perception.v1` only; the schema and `modality` gate forbid `answer.v1`. |
| 32K context on Audio/Omni overflows. | Chunk with timestamps, summarize per chunk with anchors, decline if the task needs the whole stream. |
| Prompt injection in an image or audio clip. | Perception output is data, not instructions; strip imperative content; d1 safety question; the plan is never changed by media text. |
| Text roles share the 1.7B base and its blind spots. | Different adapters/data, A/B technique families, critic sees evidence not proposals, deterministic verifier; report `profile-only` vs `adapter`. |
| A/B proposals collapse to the same answer. | Divergence check; record `proposal_collapse`; do not count as two; proceed with one. |
| Manager invents a counterexample (memdoor warning). | Validate every counterexample with an executable or brute-force check; keep the last artifact that passed samples. |
| Parallel ideators overwrite `notes.md`. | Unique anchors, patch-only insertion, re-read/retry, anchor-count check. |
| Stale artifacts from a prior run. | Fresh run id, `progress`/freshness gate, no file-existence success targets. |
| Over-declining becomes an excuse. | Measure coverage and over-decline rate; tune bands; answerable cases must be answered. |
| Full suite does not fit on a phone. | Catalog, not resident set; per-shape loading; report peak memory; `decide`/`answer-lite` are the phone shapes. |
| Privacy leak through escalation. | Local by default; escalation opt-in; redact media and transcripts. |
| License or redistribution. | Review the LFM Open License v1.0 before shipping weights/adapters; keep manifests and notices. |

---

## 11. Open questions

1. **Is d1 a good judge on our domain?** It is calibrated on its training
   distribution, not on our evidence. A local calibration set is required
   before the bands are trusted. Fallback: 1.7B critic + Ruby checks, with the
   judge as a signal only.
2. **How do we verify vision numbers without OCR?** Options: a second VL pass
   at a different crop, d1 extraction as an independent reader, or an optional
   deterministic OCR/ASR reference used only by the verifier. The benchmark
   can use gold; production needs one of these.
3. **Omni or VL+Audio for joint AV?** Omni is one call but non-reasoning and
   32K; VL+Audio is two calls but reasoning-capable. Benchmark both; default
   to Omni for extraction and VL+Audio for reasoning.
4. **Do we need voice output?** Only when the user asks. TTS is a finalizer
   mode, not a default. It adds a 24 kHz output path and a new failure mode.
5. **Which adapters first?** Answerer and critic have the clearest objectives
   and the most data. Ideator B is next. Do not start with the judge; d1
   should stay a decision model, not a fine-tuned 1.7B.
6. **What is the escalation policy?** Operator-configured frontier/human; if
   absent, return a typed decline with `escalation_unavailable`. Never fall
   back to a generalist.
7. **How much of the suite is resident?** Per shape. `decide` and
   `answer-lite` are the edge shapes; `watch` is a laptop/desktop shape.
8. **Does the team need a scout?** Not in the precomputed-evidence pilot.
   Retrieval is a separate suite; the scout remains a text role with
   allow-listed tools.

---

## 12. Recommendation

1. **Accept the hybrid design** and freeze v0 to the `decide`, `answer-lite`,
   `see` and `hear` shapes, with `watch` as an experimental arm in the
   benchmark. Add `answer-full` and make `watch` a default shape only after
   the pilot.
2. **Extend the contract layer first:** `ModelFamily`, new roles, schemas,
   reasons, hops, gates, ledger sections. Without these, the team cannot be
   expressed, let alone enforced.
3. **Add the manifests:** `triage.d1`, `triage.audio`, `judge.d1`,
   `judge.omni`, `perceiver.vision`, `perceiver.audio`, `perceiver.omni`,
   `ideator.direct`,
   `ideator.alternative`, `answerer.grounded`, `critic.claims`,
   `repairer.bounded`, `finalizer.concise`, `planner.microstep`,
   `reviewer.manager`, `escalation.frontier`.
4. **Implement the adapters as fakes first:** `D1Adapter` with typed questions
   and no sampling; VL/Audio/Omni with media fixtures; text via the existing
   command/server seam. No live calls in `rake test`.
5. **Extend the conductor:** shape selection, one parallel fan-out, two-phase
   verify, one repair round, calibration bands, receipts.
6. **Build the 24-case benchmark** with gold fields and gold anchors; run the
   pilot; publish the negative result if there is no lift.
7. **Only then** add role adapters on `LFM3-1.7B-Base`, gated on a held-out
   comparison.

The team is not powerful because it calls seven models. It is powerful because
each call has one job, one schema, one owner, one checkpoint and an honest
exit. That is the part a big model cannot give us locally, and the part the
LFM3 suite makes possible.

---

## 13. Verification checklist

- [x] Every role has an `IDENTITY`, a `CAPACITIES` allow-list and a
      `must decline when` condition.
- [x] Every model is assigned only work its card recommends.
- [x] Every artifact has one schema and one owner.
- [x] Every hop has a checkpoint; no raw model output reaches the next role.
- [x] Declines and escalations are typed, first-class and receipted.
- [x] Verification is code-first; the judge is calibrated, not verbal.
- [x] The loop matches memdoor: fresh contexts, disk ledger, independent
      proposals, non-blocking test, one repair, authoritative verify.
- [x] The benchmark has controls, a stop rule and a negative-result path.
- [x] The discovery does not depend on `runes-lang/glyphes/tmp` at runtime.
- [x] `discovery.md` and `docs/2609.20804v1.pdf` remain untracked and are not
      part of this change.

---

## Sources

- memdoor `team-solve`: README, DESCRIPTION, NOTES and `steps/*.yaml`, read
  2026-11-01 from
  <https://github.com/guregodevo/memdoor/tree/main/examples/workflows/team-solve>.
- HF model cards, read 2026-11-01:
  [LFM3-1.7B](https://huggingface.co/LiquidAI/LFM3-1.7B),
  [LFM3-1.7B-Base](https://huggingface.co/LiquidAI/LFM3-1.7B-Base),
  [LFM3-VL-2B](https://huggingface.co/LiquidAI/LFM3-VL-2B),
  [LFM3-Audio-2B](https://huggingface.co/LiquidAI/LFM3-Audio-2B),
  [LFM3-Omni-2B](https://huggingface.co/LiquidAI/LFM3-Omni-2B),
  [d1-2B](https://huggingface.co/LiquidAI/d1-2B),
  [d1-Omni-2B](https://huggingface.co/LiquidAI/d1-Omni-2B).
- Existing design: `docs/SMALL_MODEL_HARNESS_PRD.md` and
  `docs/SMALL_MODEL_HARNESS_PLAN.md`.
- Legacy controls: `lib/runes/orchestration/cumulative.rb`,
  `lib/runes/llm/bonsai_adapter.rb`, `bench/cumulative/`.
