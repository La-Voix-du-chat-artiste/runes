# PRD — the LFM3 team (Cycle 43)

**Status:** proposed · **Revised:** 2026-11-01
**Supersedes:** the text-only "specialized small-model swarm" in the previous
revision of this PRD.
**Inputs:** the
[memdoor `team-solve` workflow](https://github.com/guregodevo/memdoor/tree/main/examples/workflows/team-solve),
the [complete LFM3 collection](https://huggingface.co/collections/LiquidAI/lfm3),
and `docs/LFM3_TEAM_DISCOVERY.md` (the design source of truth).
**Companion:** `docs/SMALL_MODEL_HARNESS_PLAN.md`
**Benchmark:** `bench/swarm/` (runner, 24 cases, fixtures, README)
**Pilot report:** `bench/swarm/results/2026-11-04-pilot-report.md` +
`.json`; decision record: `bench/swarm/results/2026-11-04-pilot.md`
**Deliverable:** a local **team of contracted roles** drawn from the full LFM3
suite, supervised by deterministic Ruby, with calibrated decisions, modality
perception, first-class decline/escalation, and a reproducible 24-case
benchmark that can prove or disprove the claim.

---

## 1. Problem

The previous cycle scaled a local model by calling the **same LFM3-1.7B
checkpoint** two or three times: solver → verifier → repair, solver → critic
→ finalizer. That is not a team. It is N samples of one policy, with three
costs:

1. **Shared blind spots.** A critic built from the same checkpoint, prompt
   family and evidence tends to approve the solver's mistakes. The legacy
   Bonsai pilot showed this: the always-rewrite auditor regressed clean cases
   (C3, C8), while the code verifier/repair path was the only reliable lift.
2. **Cost without specialization.** Calling the same model multiple times
   multiplies latency, memory and energy while every call still has the same
   capabilities and the same failure modes.
3. **No accountability.** A generic agent can answer anything, so no part of
   the system can say "this is outside my role" before a fabricated answer is
   produced.

The previous design also treated LFM3-1.7B as the whole team. It is not. The
LFM3 collection contains **seven checkpoints with genuinely different jobs**,
and the contract layer built in the last cycle is **text-only by
construction**:

- `Manifest` hardcodes `LiquidAI/LFM3-1.7B`;
- `Identity::ROLES` has no perception, triage or repair roles;
- `Capacity::SCHEMAS` has no plan, proposal, perception or verdict schema;
- `Checkpoint::GATES` cannot express modality, provenance or calibration.

The team cannot be built without extending those allow-lists first. That is
the first implementation change, not an afterthought.

### 1.1 What the collection changes

| checkpoint | what it is for | what it must not be asked to do |
|---|---|---|
| **LFM3-1.7B** | local text agent: grounded QA, tool calling, structured output, 16 languages, 256K context | agentic coding, complex multi-step reasoning, planning a whole task |
| **LFM3-1.7B-Base** | adapter substrate (22T tokens) for CPT/SFT/LoRA | chat or production roles without an adapter |
| **LFM3-VL-2B** | images, video, documents, charts, screens, boxes, spatial reasoning | coding, multi-turn chat, complex reasoning |
| **LFM3-Audio-2B** | streaming ASR, speech translation, audio understanding, spoken tool calls | long-context reasoning; voice chat is English-only today |
| **LFM3-Omni-2B** | one-pass joint audio-video understanding | reasoning, planning, critique; `enable_thinking` is unsupported |
| **d1-2B** | calibrated typed decisions: triage, routing, extraction, judging, reranking, boxes, counts | chat, prose, long free-form answers |
| **d1-Omni-2B** | calibrated typed decisions over audio: spoken routing, sound events, audio triage | transcription, speech output, chat |

Three facts drive the design:

1. **`d1` is a different kind of computation.** It reads answers from one
   forward pass and returns typed probabilities instead of generating tokens.
   It is the right owner for decisions a 1.7B model should not make verbally.
2. **Perception is not reasoning.** VL, Audio and Omni produce evidence, not
   conclusions. Omni is explicitly non-reasoning.
3. **The text model is the only prose engine, and the weakest at planning.**
   It must receive one micro-task at a time, with a schema and a checkpoint,
   never a plan or a transcript.

### 1.2 What memdoor `team-solve` contributes

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

That is the supervision shape the 1.7B tier needs. Two deliberate deviations:

- **The planner is Ruby, not a model.** The 1.7B card does not recommend
  complex multi-step planning. The deterministic planner writes the DAG and
  the acceptance checks; the model sees one micro-step.
- **The manager's judgment is split.** Ruby owns the facts, the captured test
  status and the repair instructions; `d1` owns the calibrated semantic
  scores. This directly addresses memdoor's warning that a manager can invent
  a wrong counterexample: a counterexample is not accepted until an executable
  or brute-force check confirms it.

### 1.3 Legacy evidence (motivation, not the new result)

The Bonsai 2B pilot remains useful as a warning, not as evidence for LFM3:

| legacy arm | checks | case-pass | lesson |
|---|---|---|---|
| `1x` | 42/45 | 9/12 | One call is cheap but brittle. |
| `2x-forced` (same-model auditor) | 39/45 | 8/12 | Always rewriting regressed clean cases. |
| `2x-adaptive` (code verifier + repair) | 44/45 | 11/12 | The executable verifier was the lift. |
| `3x-forced` (same-model critic/finalizer) | 12/14 on targeted cases | — | More same-model calls did not beat adaptive repair. |

The new hypothesis is not "use more calls." It is "use **different,
contracted roles** and let the conductor decline or escalate when a role is
the wrong tool."

---

## 2. Design findings

1. **The suite is a division of labour, not a bigger prompt.** Each checkpoint
   has a job the others are explicitly not recommended for.
2. **`d1` is the missing decision layer.** Calibrated, typed, one-pass
   decisions fit routing, selection and claim support better than a 1.7B
   model's verbal confidence.
3. **Perception is not reasoning.** VL, Audio and Omni produce evidence; they
   must not produce conclusions.
4. **The contract layer is text-only.** `ModelFamily` is the first change;
   without it, a vision or audio manifest is either impossible or a lie.
5. **The full suite is a catalog, not a resident set.** At 4-bit the seven
   checkpoints are roughly 8–10 GB together. Per-shape loading and cold/warm
   accounting are part of the design.
6. **Memdoor's manager risk is fixed by splitting facts from scores.** Ruby
   owns the captured status and repair instructions; `d1` owns the calibrated
   scores; a counterexample must be executable.
7. **The honest claim is scoped reliability, not frontier parity.** The team
   should win on evidence-grounded, modality-specific work and decline the
   rest.

---

## 3. Goals

1. **Replace same-model repetition with a real division of labour.** Each role
   has a distinct checkpoint, identity, prompt/profile, tools, permissions,
   output schema and budget. A role may not do another role's job.
2. **Make identity and capacity explicit and enforceable.** Every agent
   declares `IDENTITY` and `CAPACITIES`; the harness binds the declaration to
   a registry manifest and rejects mismatches. Identity is assigned by the
   conductor, not chosen by the model.
3. **Use the right model family for the job.** `d1` owns typed calibrated
   decisions, VL/Audio/Omni own perception, 1.7B owns prose, Ruby owns the
   control plane.
4. **Make decline a first-class outcome.** An agent must decline work outside
   its capacities, with missing/conflicting evidence, or when it cannot
   produce a supported answer. A decline routes to another specialist or to
   escalation; it is not retried blindly.
5. **Keep verification code-first.** Citations, anchors, room status, numeric
   grounding, modality, provenance, artifact presence, truncation, contract
   compliance, calibration bands and no-progress are checked by Ruby. A
   failing verifier overrides "accept."
6. **Supervise the 1.7B at every hop.** The conductor decomposes the task into
   one-role micro-steps and runs a deterministic checkpoint after every step.
   An artifact that fails a checkpoint never reaches the next role.
7. **Measure specialization honestly.** Report case-pass, modality routing,
   perception fidelity, proposal divergence, judge calibration, decline
   precision/recall, false-answer rate, contract violations, regressions,
   calls by model/role, wall time, cold/warm and peak memory. Infra rows are
   excluded from accuracy and named.
8. **Keep Runes' shape.** No new rune verbs. The team is library classes, a
   registry, manifests and a benchmark; a workflow template is optional.

---

## 4. Non-goals

- N copies of the same model as a "team." Same-model arms remain
  controls/baselines only, never the candidate.
- General frontier parity, or a claim that 1.7B + friends beats a frontier
  model on open-ended work.
- Agentic coding or complex multi-step reasoning on the local team. The model
  cards say not to; the conductor must decline or escalate those tasks.
- Letting a model own the plan, the budget or the route. Models propose one
  artifact per call; Ruby owns decomposition, checkpoints and hops.
- Treating Omni as a reasoner, `d1` as a chat model, or a perception role as
  an answerer.
- Training a foundation model. Role adapters on `LFM3-1.7B-Base` are optional
  and gated on a held-out comparison.
- Replacing `Runes::RequestLedger` (inbound dedupe) with `WorkLedger` (shared
  run state). They answer different questions.
- Live cloud-provider or model calls in the default test suite.
- A production multi-tenant UI, auth, or a compiled fleet runtime.
- Multi-turn free-form tool use in v0. The benchmark supplies precomputed
  evidence and media; retrieval is a later, allow-listed scout suite.
- Voice output in v0. TTS is a later finalizer mode, not a perception role.

---

## 5. Users and jobs

| user | job |
|---|---|
| **Local operator** (Apple Silicon, 16 GB) | "Answer from my documents and images, decline rather than invent, and tell me which role did what." |
| **Harness developer** | "Give me manifests, a broker, a contract guard and a loop I can drive with fakes, without a model." |
| **Reviewer** | "Show me identity, capacities, decisions, decline reasons, calibration scores, the denominator and the regressions." |
| **Specialization engineer** | "Swap an answerer/critic adapter or a perception model without changing the conductor or the benchmark." |
| **Fleet/observatory owner** | "Publish the chain (task → shape → role → decision → artifact → verdict) so I can audit it later." |

---

## 6. Hypotheses

- **H1 — calibrated decisions beat verbal confidence.** Replacing verbal
  routing and verbal sufficiency with `d1` typed probabilities improves shape
  selection and claim-support decisions at a fraction of the latency.
- **H2 — modality coverage is the clearest big-model-like win.** A VL/Audio/
  Omni perception role solves tasks a text-only 1.7B cannot, with verified
  anchors.
- **H3 — contracts reduce unsupported answers.** Mandatory identity/capacity
  declarations plus a decline path reduce false answers on unsupported or
  out-of-capacity cases compared with a same-model cascade.
- **H4 — the conductor, not the model, owns identity and shape.** A contract
  guard that binds the declared identity to a registry manifest catches
  misrouting, role impersonation, modality mismatch and capacity overreach.
- **H5 — independent proposals plus calibrated selection beat one sample.**
  Diversity helps only if the proposals actually differ and the selector is
  calibrated. Both are measured.
- **H6 — supervision beats self-planning at 1.7B.** A checkpoint-gated
  micro-step loop reduces unsupported answers and no-progress loops compared
  with one prompt that asks the model to plan and execute the chain.
- **H7 — adapters beat prompt-only specialization, if the data exists.**
  Role LoRA/SFT on `LFM3-1.7B-Base` should improve text roles over profiles
  alone. This is gated: no adapter is claimed as a win without a held-out
  comparison.

---

## 7. The team

### 7.1 Planes and roster

Control plane (deterministic, no model call):

| role | identity | model | can | must decline when | schema |
|---|---|---|---|---|---|
| **Conductor** | `conductor.router@1.0.0` | Ruby | route, budget, select shape, enforce contract, escalate, decline | no shape fits, budget exhausted, task outside all manifests | `decision.v1` |
| **Planner** | `planner.microstep@1.0.0` | Ruby | decompose, choose shape, define acceptance, set anchors, budget | task out of scope, required modality absent, plan cannot be verified | `plan.v1` |
| **Reviewer** | `reviewer.manager@1.0.0` | Ruby | inspect captured test status, write review, issue repair instructions, decline | test status missing/unreadable, counterexample unvalidated | `review.v1` |
| **Verifier** | `verifier.mechanical@1.0.0` | Ruby | citations, anchors, numbers, schema, modality, provenance, truncation, artifact, progress, calibration thresholds | a check cannot be evaluated, evidence is malformed | `violations.v1` |

Decision plane (calibrated, one forward pass):

| role | identity | model | can | must decline when | schema |
|---|---|---|---|---|---|
| **Triage** | `triage.d1@1.0.0` | `d1-2B` | detect modality, classify intent, score scope/risk/sufficiency, recommend shape, decline | request unsafe, out of family, or no shape viable | `verdict.v1` |
| **Audio triage** | `triage.audio@1.0.0` | `d1-Omni-2B` | classify spoken request, detect sound events, route audio task | audio unintelligible, out of family, or no audio role fits | `verdict.v1` |
| **Judge** | `judge.d1@1.0.0` | `d1-2B` | score proposal support/coverage/risk, choose/merge/neither, score claim support/contradiction, sufficiency | evidence insufficient to score, or question outside its criteria | `verdict.v1` |
| **AV judge** | `judge.omni@1.0.0` | `d1-Omni-2B` | score audio/visual agreement, detect contradiction, choose the evidence source | media missing/unintelligible, or task is text-only | `verdict.v1` |

Perception plane (evidence only):

| role | identity | model | can | must decline when | schema |
|---|---|---|---|---|---|
| **Vision** | `perceiver.vision@1.0.0` | `LFM3-VL-2B` | read image/video/document/chart/screen, locate objects, describe scene, cite page/box/time | no image/video, media unreadable, task asks for judgment or prose | `perception.v1` |
| **Audio** | `perceiver.audio@1.0.0` | `LFM3-Audio-2B` | transcribe, translate speech, detect sound events, describe audio | no audio, audio unreadable, task asks for a decision or prose answer | `perception.v1` |
| **Omni** | `perceiver.omni@1.0.0` | `LFM3-Omni-2B` | read audio-video jointly, align speech to frames, describe joint scene | media needs reasoning, or task is text-only | `perception.v1` |

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

Every row also declares a non-empty `cannot` list, disjoint from `can`, in its
manifest; the tables show the positive allow-list and the refusal trigger to
stay readable. A capability outside `can` is an overreach even when it is not
named in `cannot`.

The existing `scout.retriever` is retained for the retrieval suite; it is not
part of the precomputed-evidence pilot.

### 7.2 Responsibility boundaries

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
needs.

### 7.3 Team shapes

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

### 7.4 The loop

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
  score each proposal: support (0..1), coverage (score), risk (score)
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
  d1: per-claim support (0..1), contradiction (0..1), answer sufficiency (0..1)
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

### 7.5 Fresh-context rules

Every role call receives exactly:

1. its assigned `IDENTITY` and `CAPACITIES` block;
2. one instruction for one micro-task;
3. the validated artifact(s) and anchors it needs;
4. the output schema and budget.

It never receives the transcript, another role's raw output, the full plan, or
a "solve the whole task" prompt. This is the main defence against context
anchoring and against same-model roles sharing blind spots.

### 7.6 Parallel-writer rules

- `plan.md` reserves unique literal anchors before any parallel call.
- Ideators patch-insert before their anchor; they never rewrite `notes.md`.
- If the ledger changed, re-read and retry a minimal insertion.
- The conductor verifies each anchor occurs exactly once before and after.
- A missing anchor is a `contract_invalid` stop, not a silent overwrite.

### 7.7 Supervision checkpoints

LFM3-1.7B is not asked to plan. It is asked to do one small thing, and Ruby
checks it before anything else happens. The gate order is fixed:

```
call → envelope → identity → capacity → decision → body → schema
     → modality → provenance → verifier → calibration → progress
     → budget → route
```

| checkpoint | owner | what it proves | failure status |
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

Rules:

1. Every gate is present on every checkpoint; a non-applicable gate is
   `:skip`, never absent.
2. A failed gate is a hard stop for that step. The raw artifact never reaches
   the next role.
3. The conductor, not the model, decomposes the task. The model gets one
   instruction per call, no prior transcript and no "plan the whole answer"
   prompt.
4. The checkpoint record is part of the route and the role receipt, so a
   reviewer can see exactly which gate stopped the run.
5. A checkpoint is not a repair loop. A contract failure is `:unverified`;
   v0 does not add a contract-repair call.

### 7.8 Calibration bands

The judge returns probabilities; the conductor applies explicit bands:

| decision | band |
|---|---|
| accept / no repair | `P(support) >= 0.80` and `P(contradiction) <= 0.10` |
| repair | `0.30 <= P(support) < 0.80` or `0.10 < P(contradiction) < 0.50` |
| decline / escalate | `P(support) < 0.30` or `P(contradiction) >= 0.50` |
| abstain | evidence readable but the requested value is absent |

The bands are configuration, not model output. They are recorded per task
family and per benchmark seed. A calibration set is required before the bands
are trusted; otherwise the judge is a suggestion, not a gate. The calibration
set must be separate from the 24-case pilot, or the ECE is in-sample and
meaningless.

### 7.9 Residency and cost

The complete suite is a catalog, not a resident set. At 4-bit the seven
checkpoints are roughly 8–10 GB together; a 16 GB laptop can hold them with
lazy loading, a phone cannot. The conductor must:

- load only the models a shape needs;
- keep an LRU cache and report cold vs warm latency separately;
- never mix cold and warm in one average;
- report per-shape peak memory, not a fictional "full suite on device" number.

This is also a design constraint: `answer-lite` and `decide` are cheap and can
run on a phone; `watch` is a laptop/desktop shape.

---

## 8. Identity and Capacity Contract (ICC)

### 8.1 Envelope

Every text-backed agent must emit a contract envelope before its body. A
tolerant section parser accepts `### IDENTITY`, `**IDENTITY**`, `IDENTITY:`
and similar spellings; JSON is preferred where the model can produce it.

```text
### IDENTITY
agent_id: answerer.grounded
version: 1.0.0
role: answerer
base_model: LiquidAI/LFM3-1.7B
adapter: answerer-grounded-lora-v1
adapter_sha256: <64 hex chars>

### CAPACITIES
can: read_evidence, answer_fr, answer_en, cite, abstain, decline
cannot: retrieve, execute_tools, write_code, verify_own_citations, answer_without_evidence
max_input_tokens: 262144
max_output_tokens: 320
output_schema: answer.v1

### DECISION
status: accept | decline | escalate
reason_code: ok | out_of_capacity | missing_evidence | conflicting_evidence |
             unsupported_claim | citation_missing | context_overflow |
             low_confidence | needs_frontier | needs_human | out_of_modality |
             needs_perception | perception_insufficient | low_support |
             proposal_collapse | repair_exhausted | unsafe_request |
             out_of_scope | ambiguous_request
next: scout | planner | reviewer | triage | judge | vision | audio | omni |
      ideator | answerer | critic | repairer | finalizer | frontier | human | null
message: <one sentence, no facts>

### BODY
<the answer, or an empty body for decline/escalate>
```

### 8.2 Echo mode and stamp mode

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
facts. This keeps "identity is assigned, not chosen" true even when the model
has no text channel to echo it.

### 8.3 Rules

1. **Identity is assigned, not chosen.** The conductor loads a manifest from
   `config/agents/<role>.json`; the model's echoed identity must match the
   assigned `agent_id`, `version` and `adapter_sha256`. A mismatch is an
   `identity_mismatch` violation, never a warning.
2. **Capacities are positive and negative.** `can` is the allow-list;
   `cannot` is mandatory. An agent that claims a capability outside its
   manifest is rejected with `capacity_overreach`. An agent that omits a
   required capability is rejected with `capacity_missing`.
3. **Decline is first-class.** `status: decline` or `status: escalate` must
   have no body (or an explicit empty body) and a typed `reason_code`.
   `status: accept` must have a non-empty body. A decline is not retried with
   the same role; the conductor routes it.
4. **The verifier owns acceptance.** Even an `accept` envelope is rejected if
   the code verifier fails. Identity/capacity compliance is necessary, not
   sufficient.
5. **Every hop is checkpointed.** The conductor never passes raw model output
   to the next role. It passes a validated artifact plus the checkpoint
   record. A failed checkpoint is a control-plane outcome (`unverified`,
   `declined`, `escalated`, `no_progress`), not a prompt to "try harder."
6. **No silent fallback.** If the conductor cannot find a role that accepts
   the task, it records `escalation_unavailable` and returns a decline to the
   caller. It does not call a generalist "just in case."
7. **No self-verification.** An answerer may not verify its own citations; a
   critic may not rewrite; a finalizer may not introduce new claims; a
   perception role may not answer. The contract guard checks the role's
   forbidden actions.
8. **Every decision is receipted.** `identity.json`, `capacities.json`,
   `decision.json`, `decline.md` (when applicable), `checkpoints.json`,
   `calibration.json` and the role receipt are written to the ledger before
   the run is considered complete.

### 8.4 Decline versus abstain versus escalate

- **Abstain** is an answer: "non documenté" with a citation line. It is
  allowed only when the answerer's capacities include `abstain` and the
  evidence is readable.
- **Decline** is a refusal to answer because the task is outside the role or
  the evidence is missing/conflicting. It produces no answer body.
- **Escalate** is a decline with a specific next hop (`frontier`, `human`,
  `scout`, `vision`, `audio`, `omni`). The conductor owns the hop; the model
  may recommend, not choose.

These are measured separately. An answerer that declines every unanswerable
case but abstains correctly on answerable-but-absent values is better than one
that blurs the two.

---

## 9. Scope (v0)

### 9.1 Library

| component | responsibility |
|---|---|
| `Runes::Swarm::Identity` | Immutable identity value: agent id, version, role, base model, adapter hash. |
| `Runes::Swarm::Capacity` | `can`, `cannot`, token budgets, output schema; subset/overreach checks. |
| `Runes::Swarm::Decision` | `accept` / `decline` / `escalate`, reason code, next hop, message. |
| `Runes::Swarm::ModelFamily` | Static facts per checkpoint: allowed base models, modalities, context, output modes, limits. |
| `Runes::Swarm::Envelope` | Tolerant parse of the `IDENTITY` / `CAPACITIES` / `DECISION` / `BODY` contract. |
| `Runes::Swarm::Manifest` | Load/validate `config/agents/*.json`; the source of truth for identity/capacity/family. |
| `Runes::Swarm::Registry` | Register/fetch roles; select roles for a task; reject unknown/duplicate ids. |
| `Runes::Swarm::CapacityBroker` | Authorize a manifest for a task/evidence/modality/budget; return a Decision before the call. |
| `Runes::Swarm::ContractGuard` | Compare the parsed envelope to the manifest; emit typed violations. |
| `Runes::Swarm::Checkpoint` | Per-step gate record: step, role, gate statuses, violations, pass/fail. |
| `Runes::Orchestration::TeamPlan` | The shape DAG, anchors, acceptance checks and budgets. |
| `Runes::Orchestration::Conductor` | Shape selection, fan-out, two-phase verify, one repair, decline routing, receipts. |
| `Runes::LLM::D1Adapter` | Typed `system_one(state, questions, media:)` decisions; no sampling, no token generation. |
| `Runes::LLM::VisionAdapter` | Image/video/document input, text output. |
| `Runes::LLM::AudioAdapter` | Audio/text input, text output in v0. |
| `Runes::LLM::OmniAdapter` | Joint audio-video input, text output in v0. |
| `Runes::LLM::Lfm3Adapter` | LFM3 text command/server seam, sampler, output cleaning. |
| `Runes::LLM::RoleProfile` | Prompt/tool/decoding profile per text role; one micro-task per prompt; optional LoRA path + hash. |
| `Runes::WorkLedger` | Add `triage.json`, `plan.md`, `perception/`, `notes.md`, `proposals/`, `review.md`, `test-status.txt`, `test-output.log`, `final-test-output.log`, `calibration.json`. |
| `Runes::RunReceipt` | Per-role receipt: identity, family, modalities, decision, calibration, prompt/completion, wall, cold/warm, status. |

### 9.2 Benchmark

- **24 cases** across six families:
  - **text QA (6):** grounded answer; absent value → abstain; conflicting
    evidence → decline; ambiguous question → clarify/decline.
  - **vision (4):** chart value; invoice fields; screen button; object
    count/box.
  - **audio (4):** ASR transcript; French audio → French text; sound event;
    spoken request → intent.
  - **audio-video (2):** speech + visual referent; audio/visual contradiction.
  - **decision (6):** intent, team routing, urgency score, extraction,
    moderation, rerank.
  - **out of scope (2):** agentic coding; long-horizon plan.
- Each case carries gold fields, gold anchors, expected shape, expected
  decision and optional `forbidden_roles`.
- **Arms:**
  - `solo-1.7B` — one text call; text baseline.
  - `solo-VL` — one VL call; vision baseline.
  - `solo-Audio` — one Audio call; audio baseline.
  - `solo-Omni` — one Omni call; AV baseline.
  - `d1-only` — triage → judge → verifier; decision baseline.
  - `text-lite` — answerer + d1 judge + verifier; cheap text team.
  - `text-full` — ideate A‖B → judge → answerer → critic → judge → repair;
    memdoor parity.
  - `perception+text-lite` — VL/Audio/Omni → text-lite; modality lift.
  - `team-full` — shape router + all roles; the candidate.
  - `frontier-1x` — external reference; gap measurement only.
  - `same-model-3x` — legacy 1.7B answer → critic → repair; control, never
    the candidate.
  - `profile-only` vs `adapter` — text roles with/without LoRA;
    specialization honesty.
- **Runner:** `bench/swarm/runner.rb` writes Markdown + JSON, one row per
  case/arm/seed, plus per-role receipts, calibration scores and decline
  reasons.

### 9.3 Integration

- Library first. A workflow template that calls `Conductor` from a `ruby`
  step is optional and does not change the seven-rune claim.
- Fleet/observatory integration is later: publish role packets and decisions
  for the O1.7 plan chain. The fleet hosts roles; it does not own the loop.

---

## 10. Benchmark protocol

### 10.1 Case shape

```json
{
  "id": "V2",
  "family": "vision",
  "question": "Quel est le total de la facture ?",
  "media": ["fixtures/invoice-07.png"],
  "gold": { "total": "128,40 €", "anchors": ["page:1", "box:412,88,980,140"] },
  "checks": { "field": "total", "must_match": "128,40" },
  "expected_shape": "see",
  "expected_decision": "accept",
  "forbidden_roles": ["answerer.without_perception"]
}
```

The benchmark uses precomputed media and evidence, so retrieval is measured in
a separate `swarm-retrieval` suite, not in the 24-case composition pilot. The
benchmark is tracked and repo-local; it never reads
`runes-lang/glyphes/tmp` at runtime.

### 10.2 Metrics

- **Task pass:** all checks pass, including expected decision.
- **Modality routing accuracy:** selected shape vs expected shape.
- **Perception fidelity:** field precision/recall, anchor validity, invented
  anchor rate, transcript WER where gold exists.
- **Proposal divergence:** fraction of A/B pairs with materially different
  approaches; unique-information gain of B over A.
- **Selection quality:** chosen proposal's pass rate vs best/worst available;
  judge calibration (ECE, Brier, AUC) on support and choice.
- **Claim support:** precision/recall of unsupported claims; false-accept
  rate.
- **Repair lift:** pass before/after; regression rate; repair-round usage.
- **Decline/escalation:** precision/recall, false-answer rate, over-decline
  rate on answerable cases.
- **Contract:** identity mismatch, capacity overreach, modality mismatch,
  provenance missing, unvalidated hops (must be 0), stale artifact reuse
  (must be 0).
- **Checkpoint pass rate:** steps that pass all gates / steps run.
- **First-failure gate:** distribution of the gate that stopped a run, so a
  prompt or role failure is visible as `envelope`, `identity`, `modality`,
  `calibration`, `verifier`, `progress`, etc.
- **Regressions:** cases where an arm fails a case its matching solo baseline
  passed.
- **Cost:** calls by model/role, tokens, wall time, cold vs warm, per-shape
  peak memory; USD only when an external provider bills.
- **Gap closure:** `(team - baseline) / (frontier - baseline)` per family,
  with a confidence interval, where the baseline is the matching single-model
  arm. If the denominator is zero or negative, report `n/a`, never a
  fabricated percentage. Report text and multimodal separately; never pool
  them into one "big-model parity" number.
- **Status:** `ok`, `repaired`, `declined`, `escalated`, `unverified`,
  `infra`, `error`, `truncated`, `empty_stop`, `no_progress`.

### 10.3 Reproducibility

- Pin each checkpoint's revision, adapter/profile id and SHA-256, sampler,
  max tokens, seed (or `seed: null` if the backend cannot honor it),
  MLX/vLLM version and quantization.
- Text samplers: ideation uses the higher-diversity setting (0.3–0.4);
  answer/critic/repair use the low-temperature setting (0.1–0.2); the
  math/STEM sampler is used only for math cases and labelled.
- `enable_thinking` is off for envelope/schema calls and on only where
  reasoning helps; the seed (or `null`) and the mode are in the receipt.
- Report cold command latency and warm server latency separately. Never mix
  them in one average.
- Cache generations separately from grading so a verifier or contract fix can
  re-score without re-calling the model. Never cache a timeout or a
  missing-binary failure as a result.
- Never overwrite a prior report; write a timestamped file and diff.

---

## 11. Success criteria and go/no-go

### v0 harness gate

- `bundle exec rake test` green; no live model or provider calls in the
  default suite.
- One opt-in live test per adapter family proves the command/server seam.
- Manifests, registry, broker, contract guard, checkpoint, team plan and
  conductor have fake-driven tests.
- No accepted artifact exists without a passing checkpoint and a verifier
  pass.
- Every injected identity, capacity, modality, provenance and calibration
  violation is caught.
- Every decline has a typed reason and a routing decision.
- Unvalidated hops = 0; stale artifacts = 0.

### Pilot gate (24 cases, 1 seed)

- `text-lite` >= `solo-1.7B` + 2 cases on the text subset, with **zero
  regressions** on cases solo passed.
- `team-full` >= `text-lite` + 2 cases on the multimodal/decision subset.
- Decline recall = **100%** on out-of-scope; false-answer rate = **0**.
- Judge ECE <= **0.10** on the calibration set.
- Capacity violations, identity mismatches, modality mismatches and
  provenance misses are **0** on accepted runs.
- Unvalidated hops = 0; checkpoint pass rate and first-failure gate are
  reported for every arm.
- Cost, warm, per shape: `decide` <= 0.5× solo, `answer-lite` <= 2×,
  `text-full` <= 4×, `team-full` <= 5×; per-shape memory reported. A single
  "3×" number would hide that `team-full` is a bigger team.
- If there is no lift, **stop** and publish the negative result. Do not add a
  fourth same-model call to rescue it.

### Pilot results (2026-11-04, 24 cases × 1 seed, cold command mode)

Full report: `bench/swarm/results/2026-11-04-pilot-report.md` + `.json`;
decision record: `bench/swarm/results/2026-11-04-pilot.md`.
**Verdict: NO-GO.**

| arm | pass | notes |
|---|---|---|
| solo-1.7B | 2/14 | text baseline |
| solo-VL | 3/4 | vision baseline |
| solo-Audio | 0/4 | audio baseline |
| solo-Omni | 0/2 | AV baseline |
| d1-only | 4/8 | false-accepts both out-of-scope cases (false-answer 1.00) |
| text-lite | 3/14 | +1 case vs solo-1.7B (gate: +2) |
| text-full | 0/14 | shape accuracy 0.00 |
| perception+text-lite | 0/10 | perception-sufficiency gate rejects all audio |
| team-full | 4/24 | 44 contract violations; decline recall 0.80; ECE 0.54 |
| same-model-3x (control) | 7/14 | beats team-full on the same cases |
| profile-only | 3/14 | no LoRA adapter exists; `adapter` arm is infra |
| frontier-1x | not run | no endpoint configured |

Gate outcomes: text lift +1 case (fail), modality lift negative (fail),
decline recall 0.80 / false-answer 0.20 (fail), contract violations 44
(fail), ECE 0.54 in-sample (fail), unvalidated hops 0 (pass). Regressions:
solo-VL passed V1–V3, team-full failed all three. Next thread: stamp-mode
envelopes for text roles (the 1.7B cannot reliably echo the four-block
envelope), then the perception-sufficiency gate and the d1 scope decline.

**Re-run 2026-11-11** (`bench/swarm/results/2026-11-11-rerun2-decision.md`,
still NO-GO): stamp-mode envelopes + scope gate + declared capacities landed.
d1-only decline recall 1.00 / false-answer 0.00 (O1/O2 decline everywhere);
solo-1.7B 7/14; team-full 6/24, ECE 0.36; envelope-structure violations
nearly gone. Text lift vs the stronger solo baseline −14.3 pp; modality lift
still negative.

**Third run 2026-11-11** (`bench/swarm/results/2026-11-11-rerun3-decision.md`):
NO-GO again — **thread closed as a published negative result** (PRD stop
condition). The 512-token-cap hypothesis was tested and refuted (team-full
6/24 → 3/24; cap reverted to 320). Landed instead: the out-of-sample
calibration set (`bench/swarm/calibration-set.json`, ECE 0.165, validates
the 0.30 sufficiency threshold; conductor reads it from `--calibration`).
Reopen only on a different model or suite.

### Product gate (24 cases, 3 seeds — follow-on only if pilot is GO)

- Gap closure >= **25%** on multimodal/decision; text gap closure reported
  honestly, even if small.
- Decline recall stays **100%**; false-answer rate stays **0**.
- Contract violations stay **0**; unvalidated hops stay **0**.
- Cost <= **5×** solo warm for `team-full`; `decide` and `answer-lite` keep
  their pilot bounds.
- No claim of open-ended parity.

---

## 12. Risks and mitigations

| risk | mitigation |
|---|---|
| "Specialized" becomes prompt theater. | Manifests, model-family assignment, adapter hashes, role-specific tests, and a `profile-only` vs `adapter` comparison. A role is not called specialized unless its behavior is measurably narrower. |
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
| Scope creep into a general agent runtime. | v0 is evidence-in, contracted-role-out; no free-form tool execution, no new rune verbs. |

---

## 13. Open questions

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

## 14. Timeline

| week | output |
|---|---|
| 1 | `ModelFamily`, roster allow-lists, schemas/reasons/hops/gates, 17 new manifests, ledger artifacts + fake tests. |
| 2 | Adapters (`D1`, `VL`, `Audio`, `Omni`, text) and echo/stamp profiles + fake tests. |
| 3 | `TeamPlan`/shape router and the conductor loop: fan-out, one repair, two-phase verify, calibration, receipts. |
| 4 | 24-case benchmark, 1-seed pilot, calibration analysis, go/no-go. |
| 5 | Adapter experiment (only if gated), hardening, docs, `ENHANCEMENT.md`; open the 3-seed product gate only on GO. |

---

## 15. Out of scope (v0)

- Agentic coding or complex multi-step reasoning on the local team.
- Free-form tool execution from model output.
- Training a foundation model or a 27B-class model.
- A new rune verb or a new agent runtime.
- Voice output and real-time streaming.
- Fleet/observatory UI for the chain (planned later).
- Cloud provider changes; the frontier arm is read-only configuration.
- Claiming a win from a single seed or a single case.

---

## 16. Success in one sentence

A reviewer can run `bench/swarm/runner.rb`, see a scoped team of contracted
roles drawn from the full LFM3 suite — calibrated `d1` decisions, verified
modality perception, supervised 1.7B prose, Ruby acceptance — see declines
routed instead of hallucinated, and read a go/no-go that measures scoped
reliability, calibration and cost rather than counting repeated calls to one
model.

---

## 17. Addendum — good-view latent layer (JEPA)

**Status:** discovery addendum, not part of v0. J0 ships if its acceptance
passes; J1 ships only on a J0 GO. The 24-case pilot, the 14-gate order for
v0/J0, the roster and the seven rune verbs stand unchanged.

### 17.1 Why

The paper (arXiv:2610.39302v1) shows that a 109M text JEPA trained on *good
views* — two observations of one scene with independent nuisances — aligns
with vision better than language models up to 72B on the paper's alignment
benchmark. Alignment is not generation. The team therefore does not claim
frontier parity; it claims scoped reliability on cross-modal,
evidence-grounded work.

| layer | implementation |
|---|---|
| multi-view sensor | `LFM3-VL-2B`, `LFM3-Audio-2B`, `LFM3-Omni-2B`, OCR/ASR |
| JEPA | a 33M–109M bidirectional good-view encoder; one rotation per modality pair |
| value head | `d1` pair validation and calibrated support |
| decoder | `LFM3-1.7B`; the captioner, not the reasoner |
| kernel | Ruby: views, trims, anchors, alignment gate, receipts |

`LFM3-1.7B` is not a JEPA. It is causal next-token; the paper's point is that
next-token positives are bad views. Frozen LFM features plus whitening are the
weak J0 fallback, not the paper's recipe.

### 17.2 J0 — frozen index (ship first)

- Add `View`, `ViewSet`, `Alignment`, `Latent`, `LatentCard` under
  `Runes::Swarm::*`; no new role.
- Add ledger artifacts `views.json`, `pairs.json`, `alignment.json`,
  `latent.json`, `latent_card.md`, `nuisance_probe.json`.
- Reuse the `judge` role as the `d1` pair validator; no new manifest.
- Fold alignment checks into `provenance` and `calibration`; do **not** change
  the 14-gate order.
- Add the 8-case `swarm-latent` suite as an addendum to the 24-case pilot, not
  a replacement.
- Acceptance: residual < .25, rank ≥ 32, spectral gap above threshold,
  `team-latent-j0` ≥ `team-full` + 1 case, zero regressions, nuisance delta
  < 5%, cost ≤ 1.5× `team-full`.

### 17.3 J1 — trained heads (benchmark-gated)

- Train a 33M–109M bidirectional encoder on trimmed good views with the
  paper's recipe; export the encoder and rotation.
- Promote `alignment` to a gate only if J1 ships: 15 gates, inserted after
  `provenance`.
- Add `alignment_unstable`, `view_conflict`, `nuisance_leak`,
  `latent_missing` as decline reasons, not errors.
- `view.v1` and `latent.v1` join `Capacity::SCHEMAS`; `pair.v1` and `probe.v1`
  stay ledger-only.
- Acceptance: residual < .15, rank ≥ 64, J1 ≥ J0 + 2 cases, zero regressions,
  cost ≤ 2× J0, consistent across three seeds.

### 17.4 J2 — latent planner (research only)

Action-conditioned prediction in the aligned space, `d1` as value head, 1–3
step search. No action-labelled data and no mechanical verifier exist yet.
Keep it off the critical path; it must beat greedy at equal calls on a
synthetic task before it touches production.

### 17.5 Benchmark controls

The `swarm-latent` suite has 8 cases (cross-modal retrieval, nuisance,
paraphrase, contradiction, AV grounding, view conflict, pair-free, rerank) and
the arms `solo-1.7B`, `team-full`, `team-latent-j0`, `team-latent-j1`,
`frontier-1x`, `same-model-3x`, `bad-view-2x`, `good-view-2x`.

The idea dies if any of these holds:

- `bad-view-2x` beats `good-view-2x`;
- `same-model-3x` matches `team-latent`;
- `no-rotation` or `random-rotation` matches the aligned arm;
- the `q` sweep (fraction of good-view pairs) does not raise task pass;
- alignment residual improves but task pass does not;
- the nuisance probe changes answers beyond threshold;
- `frontier-1x` wins every case.

A negative result is a valid outcome and is published.

### 17.6 What does not change

- Seven rune verbs; no new runtime.
- 14 gates for v0 and J0; 15 only if J1 ships.
- 24-case pilot; the latent suite is an 8-case addendum.
- Same-model arms are controls, never candidates.
- `discovery.md` and `docs/2609.20804v1.pdf` stay untracked.
- No runtime dependency on `runes-lang/glyphes/tmp`; no `docs/epics/` or
  `docs/missions/`.
