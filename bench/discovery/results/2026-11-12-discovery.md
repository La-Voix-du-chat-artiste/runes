# Discovery-phase benchmark — 2026-11-12

Three arms over `examples/discover_codebase.rb`, run against this repo with
the local `LiquidAI/LFM3-1.7B-MLX-4bit` checkpoint through the chat seam
(no cloud key). Machine-readable: `2026-11-12-discovery.json`. Runner:
`bench/discovery/run.rb`.

Brief: "Add a kanban board to the observatory: where would it plug in, what
would it read, what would it write?"

## Arms

| arm | text calls | subproblems answered | anchor_pass_rate | loop_events | coverage | verdict |
|---|---|---|---|---|---|---|
| **full** (renderings + explore + verify) | 5 | 4/4 | **1.00** | 0 | 1.00 | sufficient |
| **tree-only** (repo-map control, zero exploration) | 1 | 0/4 | n/a | 0 | 0.00 | insufficient |
| **external** (one big call) | — | infra | — | — | — | no endpoint configured |

## The number the swarm pilots could not produce

**Exploration-modality lift: full discovery answers 4/4 subproblems with
mechanically resolved anchors; the repo-map-only control answers 0/4.**
Every kept finding's anchor resolved (`file:line` inside a real file), the
loop detector recorded zero loop events across 5 consecutive 1.7B calls, and
the card's sufficiency verdict is `sufficient` only when every subproblem is
answered. The external arm is recorded as infra — no endpoint is configured
in this environment, same honesty rule as `frontier-1x` in the swarm bench.

## Honest caveats

- The 1.7B tends to copy the prompt's example anchor (the candidate file's
  first lines) rather than pinpoint the exact lines — anchors *resolve*
  (the provenance gate is mechanical), but precision is model-limited. A
  stronger model or a tighter prompt would raise anchor precision, not just
  pass rate.
- One seed, one repo, one brief. The downstream metric the design asks for
  — mission acceptance in `/build` when the mission is generated from the
  card — is not measured here.
- `RUNES_DISCOVERY_VIEWS=tree` is the control-arm switch; the external arm
  needs `RUNES_DISCOVERY_EXTERNAL_BASE_URL` + `_MODEL`.
