# Discovery phase — a contracted pre-swarm shape for the LFM3 team

> **Status:** design draft for review — not an implementation.
> **Home:** slots into the existing team loop (`docs/LFM3_TEAM_DISCOVERY.md`) and
> the workflow layer (`docs/WORKFLOWS.md`), before `/plan` → mission.
> **Doctrine inherited:** fresh contexts, the model never plans, verification
> instead of trust, decline is first-class, good views over prompt variants
> (`discovery.md`).
> **Trigger:** a vibe-coding prompt + a codebase → a **verified discovery card**
> that the mission generation (and then the swarm) consumes.

---

## TL;DR

Discovery is the task class where the team's doctrine is strongest and the
pilots' failure mode is weakest:

- **The 1.7B never plans and never holds the repo.** Ruby builds renderings of
  the codebase, Ruby builds the micro-step DAG, the model sees one micro-task
  per fresh-context call, each with a typed schema and a token cap.
- **Every discovery claim is an anchor** (`file:line` or `file:symbol`), and
  anchors are mechanically verifiable — the provenance gate applied to code.
  This is the one regime where "verification instead of trust" is nearly free.
- **Views are renderings, not prompts.** The repo at one commit sha is the
  world state; tree, imports, tests, churn and docs are different renderings of
  it. A discovery ideation pair reads *different renderings*, never prompt
  variants — the §2.2 bad-view fix, applied to code.
- **`d1` owns sufficiency.** The gate at the end is a calibrated verdict:
  is this card sufficient to generate a mission? Insufficient → targeted
  re-probe (once), then decline → external escalation synthesizes *from the
  card*, never from scratch.

Output: `discovery_card.md` + `discovery.json` (`discovery.v1`), the input
contract for `/plan`.

---

## 1. Why discovery, given the pilot results

The Cycle 43 re-run attributed the NO-GO to model capability (citations at the
320-token cap), not harness. Discovery inverts the exposure:

| pilot weakness | discovery-phase mitigation |
|---|---|
| long traces → truncation, citation failure | every call is ≤ one micro-task, typed output, hard cap |
| same-model roles share blind spots | roles differ by *rendering*, which is a genuine view difference |
| verbal confidence is not evidence | `d1` sufficiency verdict; Ruby anchor checks are facts |
| model chooses shape / wanders | Ruby owns the DAG, the file picks and the budget |
| open-ended prose exposes 1.7B weakness | the card is assembled by Ruby; the model only fills typed slots |

Discovery is also *declinable*: a repo too foreign for the suite (exotic
language, no anchors) produces `decline: out_of_scope` and escalation — exactly
the honest behaviour the team claims as its advantage.

---

## 2. World state and views (`discovery.md` §3.1, applied to code)

```
state_id    = repo_url + git_sha + sha256(task brief)
rendering   = one deterministic extraction of the repo at that sha
```

| rendering | producer | what it gives the model |
|---|---|---|
| `tree` | Ruby (`git ls-files` + LOC count + framework detection) | what exists, where mass is |
| `imports` | Ruby (require/import graph) | module coupling, entry points |
| `tests` | Ruby (test inventory per suite) | what is already verified, where behaviour is pinned |
| `churn` | Ruby (`git log` hotspots, 90 days) | where risk lives, what recently broke |
| `docs` | Ruby (README/CHANGELOG spans) | intent, as the authors wrote it |

All five are renderings of **one** `state_id` with different extraction
methods — good views by the paper's definition. Every rendering is hashed into
the receipt; the model never reads the repo directly, only trimmed renderings
and files Ruby hands it.

---

## 3. The loop — `discover` shape

```
intake      brief + repo → state_id, budget
renderings  Ruby builds the five views, hashes them
brief-split 1.7B (fresh, typed): restate the problem, list subproblems,
            mark which are codebase-dependent
scope       d1: is each subproblem in-scope for the suite?
select      Ruby ranks renderings/files against subproblems (rg + scores)
explore     map over subproblems — Ruby picks candidate files, model emits
            finding.v1 (anchors required), fresh context per item
verify      Ruby resolves every anchor (file, line range, symbol via rg)
            → violations.v1; failures route to one bounded repair
ideate A‖B  only for contested subproblems — A reads imports+docs,
            B reads tree+tests (different renderings, same state)
judge       d1: coverage / unknown-risk / sufficiency verdict
assemble    Ruby writes discovery_card.md + discovery.json
gate        sufficient → /plan consumes the card
            insufficient after one re-probe → decline: discovery_insufficient
            → external escalation synthesizes FROM the card
receipt     renderings, anchors, pass rate, loop events, budgets, verdicts
```

Deliberately linear, two fan-outs (explore, ideate), one conditional repair —
same skeleton as `answer-full`, with the perception roles replaced by
deterministic renderings.

---

## 4. Schemas

### `finding.v1` (the exploration unit)

```json
{
  "subproblem_id": "S3",
  "finding": "The MQTT5 adapter dedupes by request_id in Runes::RequestLedger",
  "anchors": ["lib/runes/transport/mqtt5.rb:88-104"],
  "symbols": ["Runes::RequestLedger"],
  "confidence": "grounded | partial | guess",
  "unknowns": ["whether the same dedupe covers tool RPC"]
}
```

### `discovery.v1` (the card)

```json
{
  "state_id": "repo:…:sha:…:brief:sha256:…",
  "problem": {
    "restatement": "…",
    "success_criteria": ["…"],
    "out_of_scope": ["…"]
  },
  "subproblems": [
    { "id": "S1", "question": "…", "status": "answered | unknown | escalated",
      "findings": ["finding.v1…"], "hypotheses": [
        { "statement": "…", "supporting_anchors": ["…"], "disconfirming_check": "…" }
      ] }
  ],
  "modules": [
    { "path": "lib/runes/…", "role": "…", "why_relevant": "…", "anchors": ["…"] }
  ],
  "unknowns": [
    { "question": "…", "why_it_matters": "…", "proposed_probe": "run this test / read this file" }
  ],
  "risks": [ { "risk": "…", "evidence_anchor": "…", "mitigation": "…" } ],
  "mission_seed": {
    "proposed_todos": ["…"],
    "acceptance_criteria": ["…"],
    "files_touched": ["…"],
    "verification_strategy": "…"
  },
  "meta": {
    "renderings_used": ["tree", "imports", "tests", "churn", "docs"],
    "calls": { "text": 0, "d1": 0 },
    "anchor_pass_rate": 0.0,
    "loop_events": 0,
    "sufficiency": { "coverage": 0.0, "verdict": "sufficient | insufficient" }
  }
}
```

Rules that make the card trustworthy:

- **An anchor is data, not prose.** A finding without a resolvable anchor is
  dropped at verify, not reworded.
- **`guess` confidence is allowed but quarantined** — it may never back a
  mission todo, only an `unknowns` entry.
- **`mission_seed` is a suggestion to `/plan`, not a plan.** The planner (Ruby)
  still owns the DAG; the seed just stops the mission phase from re-reading
  the repo.

---

## 5. The five micro-task contracts (prompts)

Each is one fresh context, one instruction, one schema, one budget — the §5.2
fresh-context rules. Skeletons:

```text
[brief-split]  You are shown ONLY the task brief. Restate it in one
  sentence, list 3–6 subproblems, mark each codebase-dependent or
  self-contained. Output JSON: {restatement, subproblems[]}. Do not
  speculate about implementation. Decline if the brief is ambiguous
  beyond one clarification.

[finding]      You are shown ONE file (or trimmed span) and ONE subproblem.
  State what the code does relevant to the subproblem, with anchors
  file:line-range. Symbols must match defn names exactly. If the span
  does not answer it, emit {finding: null, unknown: "…"}. Never invent
  an anchor. Cap: 200 tokens.

[hypothesis]    You are shown findings for one subproblem (anchors only,
  no raw code). Propose the most direct explanation; give one
  disconfirming check that Ruby could execute. Output proposal-shaped
  JSON. Decline if findings conflict.

[unknown]       For each unresolved subproblem, phrase the single question
  that unblocks it and the cheapest probe that answers it.
  No prose beyond the schema.

[risk]          You are shown churn + tests renderings. List top 3 risks
  for the *proposed change*, each with an evidence anchor and a
  mitigation. Decline if the brief poses no code change.
```

Re-ask policy mirrors `/plan`: invalid JSON → one re-ask → fail-loud, routed
as `contract_invalid`, never silently retried.

---

## 6. Loop-safety gate (where the weight-space post plugs in)

Discovery is the first place the suite will run *many* consecutive 1.7B calls —
the regime where thinking loops appeared in the Qwen study. The defence is
harness-first, weights-last:

1. **Detect in Ruby, not in the model.** After every text call, a repetition
   detector flags a repeated ≥16-token window (≥3 repeats). On detection:
   `break!` the step, record `loop_event` in the receipt, route the micro-task
   to `repair` (once) or escalate it.
2. **Cap outputs.** Loops need room; the 320-token cap lesson from the pilot
   already suppresses them. Keep every text micro-task ≤ 200–300 tokens.
3. **Measure across runs.** `loop_events / text_calls` is the loop rate.
   Below ~1%: ignore. Systemic (same layers' traces, recurring): the
   steering-vector fix is the next lever — find the anti-loop direction on
   looping vs productive traces from your own runs, add it at the global
   attention layers at inference. No weight surgery, no new artifact class.
4. **LP/weight edit only if** the steering vector works AND a self-contained
   checkpoint (no runtime hook) is a real requirement — e.g. the compiled
   Spinel path, where an inference-time hook is awkward.

The detector draft (Ruby, kernel-safe):

```ruby
LOOP_WINDOW = 16      # tokens (whitespace-split)
LOOP_REPEATS = 3      # consecutive window repeats

def loop_detected?(text, window: LOOP_WINDOW, repeats: LOOP_REPEATS)
  toks = text.to_s.split(/\s+/)
  return false if toks.size < window * repeats
  (0..(toks.size - window * repeats)).each do |i|
    w = toks[i, window]
    next if w.uniq.size < window / 2          # degenerate window
    count, j = 0, i
    while toks[j, window] == w
      count += 1
      j += window
    end
    return true if count >= repeats
  end
  false
end
```

---

## 7. Benchmark discipline (receipts, not vibes)

Discovery must be measured the way the pilots were — with controls:

- **Arm 1 — full discovery:** renderings + explore + verify + judge.
- **Arm 2 — repo-map-only control:** card from `tree` alone, zero exploration.
  The lift of Arm 1 over Arm 2 is the exploration modality lift — the exact
  number the last pilots could not produce.
- **Arm 3 — escalation baseline:** one external model call, same brief.
  Honest comparison: does contracted discovery beat one big call at cost X?

Metrics per run: `anchor_pass_rate` (target ≥ 0.9 pre-repair),
`loop_events`, calls/tokens per arm, decline rate, and the downstream metric
that actually matters — **mission acceptance**: fraction of `/build` todos
that pass QA verifiers when the mission was generated from the card. A
beautiful card that yields failing missions is a NO-GO.

Label the arms honestly: all text micro-tasks are the same base model, so
`profile-only` until role LoRAs exist; the genuine diversity is the
renderings, and the receipt says which views each ideator saw.

---

## 8. Prototype — workflow layer first, swarm layer second

The contracted layer needs `discovery.v1`/`finding.v1` in `Capacity::SCHEMAS`
and new reasons in `Decision::REASONS` (§9). So: prototype in the
Roast-compatible workflow layer, with the same artifacts on disk, then
graduate. Draft (`examples/discover_codebase.rb`):

```ruby
# examples/discover_codebase.rb
# Discovery phase prototype: brief + repo -> verified discovery card.
# No model call sees the repo directly; every claim is anchored.
#
#   bin/runes-workflow execute examples/discover_codebase.rb

BRIEF = ENV.fetch("RUNES_DISCOVERY_BRIEF") # the vibe-coding prompt, verbatim

execute do
  # ── Phase 0 — world state (deterministic, no model) ──────────────
  cmd(:git_sha) { ["git", "rev-parse", "HEAD"] }
  cmd(:git_ls)  { ["git", "ls-files"] }
  cmd(:git_log) { ["git", "log", "--oneline", "--since=90.days", "-500"] }

  ruby(:renderings) do
    files = cmd!(:git_ls).lines.map(&:strip)
    {
      state_id: "sha:#{cmd!(:git_sha).out.strip}",
      tree:     files.group_by { |f| File.dirname(f) }.transform_values(&:size),
      tests:    files.select { |f| f =~ /(_test|spec|test_)\.rb$/ },
      churn:    cmd!(:git_log).lines.map(&:strip).first(200),
      imports:  files.select { |f| f.end_with?(".rb") }.to_h { |f|
                  [f, File.read(f).scan(/^\s*(?:require|require_relative)\s+["']([^"']+)["']/).flatten]
                rescue nil # unreadable file: excluded, recorded in receipt
                }
    }
  end

  # ── Phase 1 — brief split (one fresh context, typed) ────────────
  chat(:brief_split) do
    <<~PROMPT
      #{BRIEF}

      Restate this task in one sentence, then list 3–6 subproblems.
      Mark each: codebase-dependent or self-contained.
      Output JSON only: {"restatement": "...", "subproblems":
      [{"id": "S1", "text": "...", "needs_codebase": true}]}
      If the task is ambiguous, output {"decline": "reason"}.
    PROMPT
  end

  ruby(:subproblems) do
    raw = chat!(:brief_split).response
    json = JSON.parse(raw[/\{.*\}/m]) # strict parse; re-ask policy upstream
    fail! "brief_split declined" if json["decline"]
    json["subproblems"]
  end

  # ── Phase 2 — exploration (one fresh context per subproblem) ────
  map(:explore, ruby!(:subproblems)) do
    sp = iteration # one subproblem
    # Ruby picks candidates: cheap, deterministic, no model choice
    candidates = from(:renderings)[:imports].keys
      .select { |f| File.read(f) =~ /#{Regexp.escape(sp["text"].split.first(3).join("|"))}/i rescue false }
      .first(3)
    next! if candidates.empty?

    chat(:one_finding) do
      <<~PROMPT
        Subproblem: #{sp["text"]}
        File (trimmed): #{File.read(candidates.first, 4000) rescue "unreadable"}

        State what this code does that answers the subproblem, with an
        anchor "path:startline-endline". Symbols must match defined names.
        If it does not answer, output {"finding": null, "unknown": "..."}.
        Never invent an anchor. Max 200 tokens.
      PROMPT
    end
  end

  # ── Phase 3 — anchor verification (authoritative, Ruby) ────────
  ruby(:verify) do
    findings = collect(:explore)
    findings.map do |f|
      anchor = f[/([\w\/.-]+\.rb):(\d+)-(\d+)/]
      path, a, b = anchor&.split(":")
      ok = path && File.exist?(path) &&
           File.foreach(path).count >= b.to_i
      { finding: f, anchor:, resolved: !!ok }
    end
  end

  # ── Phase 4 — loop-safety + assembly (Ruby, never the model) ────
  ruby(:card) do
    verified = ruby!(:verify)
    # loop_detected?(text) per §6; quarantine unresolved anchors;
    # assemble discovery_card.md + discovery.json (schema §4)
    { anchor_pass_rate: verified.count { |v| v[:resolved] } / [verified.size, 1].max,
      findings: verified }
  end
end
```

(The `map` collection-passing and `iteration` accessor follow the Roast form;
adjust to the runes runner as needed. `d1` sufficiency-judging and the
`ideate A‖B` contested-subproblem fan-out are left as insertion points — they
belong to the contracted layer where `verdict.v1` exists.)

## 9. Graduating to the swarm layer — the contract diff

- `Capacity::SCHEMAS` += `discovery.v1`, `finding.v1`
- `Identity::ROLES` += `discoverer` (text plane; fresh context per call)
- `Decision::REASONS` += `discovery_insufficient`, `anchor_unresolved`, `loop_detected`
- `Decision::HOPS` += `discoverer`
- New shape `discover`, prepended to the mission flow:
  `discover → /plan (mission from card) → swarm launch`
- Gates unchanged: `provenance` is the anchor check; `calibration` carries the
  `d1` sufficiency bands; `progress` fails re-emitted cards.
- Receipt adds: `renderings`, `anchor_pass_rate`, `loop_events`, view
  assignment per ideator (the honest `profile-only` labelling).

---

## 10. Open questions (deliberately not decided here)

1. **Language scope.** Anchor verification via `rg` is trivial for Ruby/Python/
   TS; exotic languages weaken the provenance gate — declare them out of
   scope first, widen later.
2. **Cost target.** A useful ceiling: discovery should cost ≤ 15 text calls +
   2 `d1` calls for a mid-sized repo. Above that, escalate by policy.
3. **Card freshness.** `state_id` binds the card to a sha; a dirty tree or a
   rebase invalidates it — cheap to detect, must be a gate, not a convention.
4. **When to skip discovery.** Self-contained briefs (no codebase) should
   route directly to `/plan`; forcing discovery there wastes the budget the
   pilots showed you don't have.