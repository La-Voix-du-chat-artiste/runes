# LFM3 Phase 6 — remaining work (2026-11-04)

> **Closed 2026-11-05** — all items landed in `cff3d14` (assets, pilot,
  docs, commit, acceptance verified). Verdict: NO-GO; the open follow-ups
> live in `ENHANCEMENT.md` §6 (echo-envelope fix, perception gate, d1
> scope decline).

## 1. Assets

- `bench/swarm/README.md`: setup, cold/warm, arms, metrics, caveats;
- `bench/swarm/export_fixtures.rb`: copy the synthetic media to a portable directory;
- `bench/swarm/fixtures/SOURCES.md` and `bench/swarm/fixtures/index.json`;
- `.gitignore` entries for `bench/swarm/runs/`, `bench/swarm/cache/`, `bench/swarm/adapters/`.

## 2. Pilot

- **Run matrix**:
  - `solo-1.7B`, `solo-VL`, `solo-Audio`, `solo-Omni`, `d1-only`, `text-lite`, `text-full`, `perception+text-lite`, `team-full`: 24 cases × 1 seed for the pilot; warm server preferred; one cold command run per family for latency;
  - `frontier-1x`: optional, only if an endpoint is configured;
  - `same-model-3x`: one seed, as a control;
  - `profile-only` vs `adapter`: only if an adapter exists; otherwise report `profile-only` and say so.

- **Analysis**:
  - Text lift: `text-lite` task-pass minus `solo-1.7B` on the text subset;
  - Modality lift: `perception+text-lite` and `team-full` minus their matching solo baselines on the vision/audio/AV subsets;
  - Shape accuracy: selected shape vs expected shape per family;
  - Perception fidelity: field precision/recall, anchor validity, invented anchor rate, WER where gold exists;
  - Proposal divergence and selection: A/B difference rate; chosen proposal pass rate vs best/worst; judge ECE/Brier/AUC;
  - Claim support and repair: unsupported-claim precision/recall; false-accept rate; pass before/after repair; repair-round usage;
  - Decline correctness: precision/recall on out-of-scope and the unsupported subset; over-decline rate on answerable cases;
  - Contract compliance: identity mismatches, capacity overreach, modality mismatch, provenance missing, unvalidated hops (must be 0), stale artifacts (must be 0);
  - Supervision cost: checkpoint pass rate, first-failure gate distribution;
  - Cost: calls by model/role, tokens, wall time, cold vs warm, per-shape peak memory;
  - Gap closure: per family, with the matching baseline; `n/a` when the denominator is zero or negative;
  - Regressions: cases a solo baseline passed and the team failed.

- **Decision record** (`bench/swarm/results/2026-11-01-pilot.md` and `.json`):
  - The exact model/revision/quantization/runtime/sampler per family;
  - The arm table with denominators and infra rows;
  - The calibration file and its SHA-256;
  - The per-case failures with the raw ledger path;
  - A verdict: `GO`, `NO-GO`, or `INCONCLUSIVE`;
  - One paragraph naming the next thread, or saying the thread is closed.

## 3. Docs

- `docs/SMALL_MODEL_HARNESS_PRD.md`: link the plan and the report; update the pilot table;
- `ENHANCEMENT.md`: a short "Cycle 43" entry with the verdict and the next thread.

## 4. Commit

```bash
bench: run the contracted LFM3 team over the 24-case benchmark
```

## 5. Acceptance

- The pilot covers all 24 cases and every arm in the run matrix;
- Every claim in the decision record points to a report row;
- No "promising" without a number;
- The negative-result path is written, not implied.