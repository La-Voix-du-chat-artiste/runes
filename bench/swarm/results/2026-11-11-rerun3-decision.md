# LFM3 team pilot — third run: token-cap hypothesis refuted, thread CLOSED (2026-11-11)

**Verdict: NO-GO, third time — the Cycle 43 thread is now closed as a
published negative result** (PRD §11 pilot gate: "If there is no lift,
**stop** and publish the negative result."). Report:
`2026-11-11-rerun3-report.md` + `.json` (8 arms, 80 rows, 0 infra, 24 cases,
seed 0, cold command, same MLX packs/revisions; `--max-tokens 512` and
`--calibration bench/swarm/calibration-set.json`, whose SHA-256 is in the
report meta).

## What this run tested

The rerun2 decision record's next thread: "answer quality at the 320-token
cap — raise per-role max_output_tokens or tighten checks". This run raised
the cap to 512 for all text roles (including the solo baseline, so the
comparison stayed fair) and passed the new out-of-sample calibration set.

## Result: the 512 cap is worse, not better (rerun2 → rerun3)

| arm | pass | decline recall | false-answer | ECE |
|---|---|---|---|---|
| solo-1.7B | 7/14 → **4/14** | 0.25 → **0.00** | 0.75 → **1.00** | n/a |
| text-lite | 3/14 → 3/14 | 0.75 → 1.00 | 0.25 → 0.00 | 0.338 → 0.342 |
| team-full | 6/24 → **3/24** | 0.80 → 0.80 | 0.20 → 0.20 | 0.359 → 0.527 |
| perception+text-lite | 1/10 → 0/10 | 1.00 → 1.00 | 0.00 → 0.00 | 0.404 → 0.473 |
| d1-only | 4/8 → 4/8 | 1.00 → 1.00 | 0.00 → 0.00 | 0.276 → 0.276 |

New failure mode at 512 tokens: the 1.7B copies the prompt's scaffolding
verbatim — `unknown decision status "accept | decline | escalate"` (the
model echoes the options line as the status; `decision_invalid` 4,
`identity_missing` 3 on team-full) — and the solo baseline false-accepts
O1/O2 again (decline recall 0.00, false-answer 1.00). Text subset: solo
0.50 → 0.29, team-full 0.36 → 0.21. **The cap is reverted to 320** (the
rerun2 configuration, which measured best).

## What this run did validate

- **The out-of-sample calibration set works**: `bench/swarm/calibration-set.json`
  (20 synthetic items disjoint from the 24 cases, scored by the real d1
  checkpoint; ECE 0.165, Brier 0.103) confirms the 0.30 sufficiency
  threshold as the misclassification-minimizing choice. The conductor now
  reads `sufficiency_threshold` from the calibration file
  (`--calibration`), and the runner strips the set's items/pairs so they
  never reach a model prompt. Builder: `bench/swarm/build_calibration_set.rb`.
- Audio perceptions still score 0.07–0.25 against the 0.30 gate — the
  calibration set is text/image-weighted, so audio needs its own items
  before the gate is trusted for audio.

## Verdict and thread closure

Three pilots (2026-11-04, 2026-11-11 rerun2, 2026-11-11 rerun3), all NO-GO.
The harness defects found along the way are fixed and measured (stamp-mode
envelopes, scope gate with declared capacities, think-stripping, calibration
set). The remaining gap is the 1.7B's capability at a 320-token cap:
citation-grounded answers and audio perception sufficiency. Raising the
token cap does not fix it (this run). Per the PRD stop condition, the
thread is **closed as a negative result**: the contracted team does not
beat the solo baseline on this 24-case suite, and the decision records are
committed under `bench/swarm/results/`. If the thread reopens, it reopens
on a different model or a different suite — not on more calls or more
tokens.
