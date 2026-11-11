# LFM3 team pilot — re-run decision record (2026-11-11)

**Verdict: still NO-GO, but the harness fixes landed and decline correctness
is now correct.** Follow-up to `2026-11-04-pilot.md` (NO-GO). Report:
`2026-11-11-rerun2-report.md` + `.json` (8 arms, 80 rows, 0 infra, 24 cases,
seed 0, cold command mode, same MLX packs and revisions as the pilot).

## What changed since the pilot (all in this commit)

1. **Stamp-mode envelopes for text roles** — `Envelope.stamp_text` stamps the
   manifest's identity/capacity around the model's DECISION+BODY; a complete
   echo is kept so the guard can still flag a mismatch; plain prose is an
   accept whose body is the text. Shared by the conductor and the runner's
   solo path. The echo-mode prompt now asks for two blocks, not four.
2. **Safety verdicts gate even a forced shape** — `select_shape` checks
   terminal/unsafe/out-of-scope *before* returning `@forced_shape` (the
   d1-only arm forced `decide` and never escalated).
3. **Triage state carries the declared capacities + known limits** — the
   scope question is judged against what the registry actually grants
   (incl. the 1.7B's "no planning" limit).
4. **Think-tag stripping in `AdapterSupport.clean_output`** (closed blocks
   only) and a readable perception text for the judge (was raw JSON).

## Results: pilot (2026-11-04) → re-run (2026-11-11)

| arm | pass | decline recall | false-answer | ECE | violations |
|---|---|---|---|---|---|
| solo-1.7B | 2/14 → **7/14** | 0.25 → 0.25 | 0.75 → 0.75 | n/a | 2 → 10 |
| solo-VL | 3/4 → 3/4 | n/a | n/a | n/a | 0 → 0 |
| solo-Audio | 0/4 → 0/4 | n/a | n/a | n/a | 0 → 0 |
| solo-Omni | 0/2 → 0/2 | 0.00 → 0.00 | 1.00 → 1.00 | n/a | 0 → 0 |
| d1-only | 4/8 → 4/8 | **0.00 → 1.00** | **1.00 → 0.00** | 0.276 → 0.276 | 4 → 4 |
| text-lite | 3/14 → 3/14 | 1.00 → 0.75 | 0.00 → 0.25 | 0.408 → 0.338 | 30 → 45 |
| perception+text-lite | 0/10 → 1/10 | 1.00 → 1.00 | 0.00 → 0.00 | 0.540 → 0.404 | 25 → 42 |
| team-full | 4/24 → **6/24** | 0.80 → 0.80 | 0.20 → 0.20 | 0.537 → **0.359** | 44 → 51 |

- **Decline correctness fixed**: O1 and O2 now decline on every conductor arm
  (`needs_frontier`, escalation unavailable); d1-only false-accepts are gone
  (decline recall 1.00, false-answer 0.00). solo-1.7B declines O2 with
  `out_of_scope` (pass).
- **Envelope contract failures nearly eliminated**: team-full violations are
  now content checks (`citation_missing` 23, `truncated_suspect` 14), not
  contract structure (`identity_missing`/`capacity_missing`/`decision_invalid`
  1 each, vs `output_schema_unknown` 2 + `identity_missing` 1 in the pilot).
- **Text lift (n=14)**: solo-1.7B 0.14 → 0.50, text-lite 0.21 → 0.21,
  team-full 0.29 → 0.36. team-full vs solo: +14.3 pp → **−14.3 pp** (the solo
  baseline improved more than the team). Gate (text-lite ≥ solo + 2 cases):
  still failing.
- **Modality lift (n=10)**: team-full 0.00 → 0.10, perception+text-lite
  0.00 → 0.10 vs solo-VL 0.75 — still negative. Audio cases still decline at
  the perception-sufficiency gate (d1 scores 0.10–0.25 vs the 0.30 threshold —
  up from 0.03–0.07 in the pilot after the think-strip fix, still below).
- **Regressions**: solo-1.7B passed T5, D2, D3, O2 and team-full failed them;
  solo-VL passed V1, V3 and team-full failed them (repair_exhausted).
- **Dominant remaining failure mode**: `repair_exhausted` / `no_progress` —
  the 1.7B's answers at 320 tokens miss citations/patterns and one repair
  round does not clear the verifier.

## Verdict

**NO-GO stands.** The pilot gate still fails: text lift is negative against
the (now much stronger) solo baseline, modality lift is negative, and
team-full passes 6/24. But the two harness-level defects from the pilot are
fixed and measured: the echo-envelope contract (stamp mode) and decline
correctness (scope gate + declared capacities). The remaining gap is model
capability, not harness: citation-grounded answers at 320 tokens and audio
perception sufficiency.

## Next thread

The thread moves from harness to **answer quality at the token cap**: raise
per-role `max_output_tokens` for answerer/finalizer (320 → 512+) or tighten
the checks to what a 1.7B can reliably emit, and re-run `text-lite` /
`team-full` on the 14 text-subset cases. In parallel, the perception
sufficiency threshold (0.30) vs the d1 judge's audio scores (0.10–0.25) needs
a real calibration set — the current ECE is in-sample. If the lift stays
negative after that, publish the negative result and close the thread per
the PRD's stop condition.
