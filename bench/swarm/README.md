# Swarm benchmark — the contracted LFM3 team over 24 cases

This directory runs the 24-case benchmark from
`docs/SMALL_MODEL_HARNESS_PLAN.md` (Phase 6/7) against the contracted team:
every model call goes through a manifest in `config/agents/`, an
`Envelope` with identity/capacity/decision, a `ContractGuard` checkpoint and
a `WorkLedger` receipt. The runner never reads a reference checkout; cases,
evidence and media are frozen in `cases.json` + `fixtures/` (see
`fixtures/SOURCES.md`, hashes in `fixtures/index.json`).

## Setup

- Ruby >= 3.3 (stdlib only for the harness itself).
- One interpreter with `mlx-vlm` (Apple Silicon) for the MLX packs, e.g.:
  `uv venv tmp/venv-swarm && tmp/venv-swarm/bin/pip install mlx-vlm huggingface_hub`
- The checkpoints (official MLX 4-bit packs, ~8–10 GB together):
  `LiquidAI/LFM3-1.7B-MLX-4bit`, `LiquidAI/LFM3-VL-2B-MLX-4bit`,
  `LiquidAI/LFM3-Audio-2B-MLX-4bit`, `LiquidAI/LFM3-Omni-2B-MLX-4bit`,
  `LiquidAI/d1-2B-MLX-8bit`, `LiquidAI/d1-Omni-2B-MLX-8bit`.
  Point the runner at them with `--model`, `--vl-model`, `--audio-model`,
  `--omni-model`, `--d1-model`, `--d1-omni-model` (HF repo ids work; the
  CLIs download on first use).
- `export LFM3_PYTHON=/path/to/venv/bin/python` or pass `--python`.

## Dry run

No model is needed:

```bash
ruby bench/swarm/runner.rb --dry-run --case T1
ruby bench/swarm/runner.rb --dry-run --arm team-full
```

Prints the selected shape, roles, checks and every role prompt; calls no
model.

## Cold command run (one process per call)

```bash
ruby bench/swarm/runner.rb \
  --arm team-full --seeds 0 \
  --model LiquidAI/LFM3-1.7B-MLX-4bit \
  --vl-model LiquidAI/LFM3-VL-2B-MLX-4bit \
  --audio-model LiquidAI/LFM3-Audio-2B-MLX-4bit \
  --omni-model LiquidAI/LFM3-Omni-2B-MLX-4bit \
  --d1-model LiquidAI/d1-2B-MLX-8bit \
  --d1-omni-model LiquidAI/d1-Omni-2B-MLX-8bit \
  --python tmp/venv-swarm/bin/python \
  --calibration bench/swarm/calibration.json \
  --out bench/swarm/results/2026-11-04-team-full.md \
  --json bench/swarm/results/2026-11-04-team-full.json
```

Command mode spawns `lfm3_cli.py` / `lfm3_media_cli.py` / `d1_cli.py` per
call: the model loads cold every time. That is the latency number to report
per family; it is recorded as `cold: true` on every row.

## Warm server run

Preferred when a server can host the checkpoints. The stock server serves
one model, and the runner takes a single `--base-url`, so a warm run covers
one family at a time (e.g. the text family on `LFM3-1.7B`):

```bash
"$LFM3_PYTHON" -m mlx_vlm.server --model LiquidAI/LFM3-1.7B-MLX-4bit
ruby bench/swarm/runner.rb --arm solo-1.7B --seeds 0 \
  --base-url http://127.0.0.1:8080 --model lfm3-1.7b-mlx-4bit \
  --out ... --json ...
```

Rows record `warm: true`. Never average cold and warm runs together.

## Arms

| arm | kind | runs on | purpose |
|---|---|---|---|
| `solo-1.7B` | one text call | text, decision, out_of_scope | text baseline |
| `solo-VL` | one VL call | vision | vision baseline |
| `solo-Audio` | one Audio call | audio | audio baseline |
| `solo-Omni` | one Omni call | audio-video | AV baseline |
| `d1-only` | triage → typed decision → verifier | decision, out_of_scope | decision baseline |
| `text-lite` | answerer + d1 judge + verifier | text, decision, out_of_scope | cheap text team |
| `text-full` | ideate A‖B → judge → answerer → critic → judge → repair | text, decision, out_of_scope | memdoor parity |
| `perception+text-lite` | VL/Audio/Omni → text-lite | vision, audio, audio-video | modality lift |
| `team-full` | shape router + all roles | all 24 | the candidate |
| `frontier-1x` | external endpoint (`--base-url` + `--model`) | text, decision, out_of_scope | gap measurement; optional |
| `same-model-3x` | legacy `Cumulative`, 3 calls | text, decision, out_of_scope | control, never the candidate |
| `profile-only` / `adapter` | text roles with/without LoRA | text, decision, out_of_scope | specialization honesty; `adapter` is an infra row unless a manifest carries an `adapter_sha256` |

Repeat `--arm` or comma-separate. `--case` selects cases; default all 24.

## What the runner records

For every `(case, arm, seed)` a ledger under `bench/swarm/runs/<case>-<arm>-s<seed>/`,
then a row with: status, selected shape vs `expected_shape`, decision vs
`expected_decision`/`expected_reason`, independent `Checks` re-scoring of the
final artifact, checkpoints with per-gate pass/fail, calibration pairs,
contract violations, route, calls (model/role/wall time/chars), cold/warm,
and the raw ledger artifacts. Infra rows (timeout, missing binary,
unavailable server, unreadable fixture) are named and excluded from every
accuracy denominator.

The report (`report.rb`) writes Markdown + JSON with `## Summary`,
`## Families`, `## Supervision`, `## Calibration`, `## Denominator` and
`## Per case` sections, plus provenance: model names, sampler, seed, the
cases-file SHA-256 and the calibration-file SHA-256. It never overwrites an
existing path.

## Metrics

- task pass and checks passed/total per arm and per family;
- shape accuracy (selected vs expected shape);
- perception fidelity (perception checks re-scored mechanically);
- proposal divergence (A/B sha256 differ) and selection quality;
- judge calibration: ECE (10 bins) and Brier over the recorded pairs;
- decline precision/recall and false-answer rate on expected-decline rows;
- contract violations by code; unvalidated hops (must be 0 on accepted
  runs); first-failure gate distribution; checkpoint pass rate;
- regressions vs a `--baseline` JSON report;
- cost: calls by model/role, prompt/completion chars, wall time, cold vs
  warm.

## Cache and reuse

Successful text generations are cached under `bench/swarm/cache/` by
SHA-256 of (model, sampler, role, max_tokens, prompt). Timeouts and missing
binaries are never cached. `--reuse` reads only — a cache miss becomes an
infra row instead of a live call. `--no-cache` disables both. Media and d1
calls are not cached.

## Fixtures

`fixtures/` holds 12 synthetic media files (CC0-1.0); `fixtures/SOURCES.md`
describes each one and its gold, `fixtures/index.json` pins the SHA-256s.
Share them without the repo with:

```bash
ruby bench/swarm/export_fixtures.rb --out /tmp/swarm-fixtures
```

## Caveats

- Command mode fixes `--max-tokens` at process launch; per-role token
  overrides only apply in server mode.
- `mlx_vlm.generate` may not honour a seed; the report records the seed it
  was given and never claims deterministic sampling the backend cannot
  provide.
- The mechanical checks are necessary, not sufficient: read the raw ledger
  artifacts before calling a lift semantic.
- A 24-case, 1-seed pilot is a decision record, not a product gate.
- Local marginal USD is unknown; the report records calls, chars and wall
  time, not a made-up price.
