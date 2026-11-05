# Cumulative small-model benchmark

This directory ports the 12-case Bonsai pilot into a repo-local benchmark. It
runs the same evidence-grounded questions at 1×, 2× and 3× model calls, verifies
the final artifact with code, and writes a Markdown + JSON report.

The benchmark does **not** read `runes-lang/glyphes/tmp` at runtime. The cases
and evidence are frozen in `cases.json`; the external checkout is provenance
only. See `provenance` in that file for the source graph and database hash.

## Setup

- Ruby >= 3.3 (the library uses only stdlib).
- A local Bonsai 2B MLX pack, for example:
  `export BONSAI_MODEL=/path/to/bonsai2-2b-mlx`
- An interpreter with `mlx-vlm` installed:
  `export BONSAI_PYTHON=/path/to/venv/bin/python`
- The stock `mlx_vlm.generate` CLI must accept `--temperature`, `--top-p`,
  `--top-k`, `--presence-penalty` and `--no-verbose`. The reference run used
  the project's isolated venv; record the installed `mlx-vlm` version in the
  report when it matters.

## Protocol

The reference pilot used the model card's non-thinking sampler:

| knob | value |
|---|---|
| temperature | 0.7 |
| top_p | 0.80 |
| top_k | 20 |
| presence_penalty | 1.5 |
| max_tokens | 320 |

The thinking sampler (`1.0 / 0.95 / 20 / 1.0`, `max_tokens >= 8192`) is a
control only; do not mix it with the default table.

`mlx_vlm.generate` may not honour a seed. When it does not, record `seed: null`
and use the run index as the only variance control. Never claim deterministic
sampling when the backend cannot provide it.

## Dry run

No model is needed:

```bash
ruby bench/cumulative/runner.rb --dry-run
ruby bench/cumulative/runner.rb --dry-run --case G1 --case C5
```

## Cold command run

```bash
export BONSAI_MODEL=/path/to/bonsai2-2b-mlx
export BONSAI_PYTHON=/path/to/venv/bin/python

ruby bench/cumulative/runner.rb \
  --arm 2x-adaptive \
  --seeds 0,1,2 \
  --command "bench/cumulative/bonsai_cli.py --model $BONSAI_MODEL --python $BONSAI_PYTHON" \
  --out bench/cumulative/results/2026-10-27-2x-adaptive.md \
  --json bench/cumulative/results/2026-10-27-2x-adaptive.json
```

Arms: `1x`, `2x-adaptive`, `2x-forced`, `3x-adaptive`, `3x-forced`,
`frontier-1x`. The forced arms are controls, not candidates: they always spend
the full call budget. The adaptive arms call again only when a code check fails.

`frontier-1x` is the same runner pointed at an OpenAI-compatible endpoint:

```bash
ruby bench/cumulative/runner.rb \
  --arm frontier-1x \
  --base-url http://127.0.0.1:8080 \
  --model some-frontier-model
```

A missing `--base-url` or `--model` is rejected with an actionable error.

## Warm server run

The stock server is preferred; do not add a custom Python server unless the
stock one cannot carry the sampler:

```bash
"$BONSAI_PYTHON" -m mlx_vlm.server --model "$BONSAI_MODEL"
ruby bench/cumulative/runner.rb \
  --arm 2x-adaptive \
  --base-url http://127.0.0.1:8080 \
  --model bonsai-2b \
  --out bench/cumulative/results/2026-10-27-2x-adaptive-warm.md
```

Report warm latency separately. Never average cold and warm runs together.

## What the runner records

For every `(case, arm, seed)` it writes a ledger under
`bench/cumulative/runs/<case>-<arm>-s<seed>/`, then records:

- status (`ok`, `repaired`, `unverified`, `infra`, `truncated`, `empty_stop`,
  `no_progress`, `error`);
- independent benchmark checks (`must_cite`, `must_match`,
  `must_not_match`), passed/total and case-pass;
- calls, per-call wall time, prompt/completion chars, finish reason;
- violations, final artifact, raw draft/critique/final artifacts;
- infra rows, which are named and excluded from the accuracy denominator.

The report never overwrites an existing path. Pass a new `--out`/`--json` or
let the default timestamped name apply.

## Cache and reuse

Successful generations are cached under `bench/cumulative/cache/` by SHA-256 of
the exact prompt, model, sampler and max-token cap. Timeouts and missing-binary
failures are never cached. `--reuse` reads only; a missing cache entry becomes
an infra row instead of a live call. `--no-cache` disables both reads and
writes.

## Caveats

- Local marginal USD is unknown unless an explicit energy estimate is used;
  the report records calls, chars and wall time, not a made-up price.
- Command mode fixes `--max-tokens` when the CLI process is launched. Per-role
  token overrides are only effective in server mode.
- The mechanical checks are necessary, not sufficient. Read the raw artifacts
  before calling a lift semantic.
- A 12-case pilot is a decision record, not a product gate.
