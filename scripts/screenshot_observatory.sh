#!/usr/bin/env bash
# Screenshots the observatory pages this repo's README points at.
#
#   scripts/screenshot_observatory.sh                 # latest run, docs/images/
#   scripts/screenshot_observatory.sh http://host:3100 /tmp/shots <run_id>
#
# Preconditions: the observatory is running (`cd runes_observer && bin/rails
# server`), an ingest is attached (`bin/runes-ingest`), and there is a workflow
# run to show — `scripts/demo_pipeline_run.rb` produces one:
#
#   RUNES_DEMO_SCRIPTED=1 RUNES_TELEMETRY=mqtt PROSPECT_ROOT=tmp/prospect-demo \
#     bundle exec ruby -Ilib scripts/demo_pipeline_run.rb
#
# Requires Google Chrome and ImageMagick (`magick`). Notes from getting this to
# work, so the next person does not rediscover them:
#
#   * `--headless=new --no-sandbox` is required inside a sandboxed shell;
#     plain `--headless` traps (SIGTRAP) and `--blink-settings=scriptEnabled=false`
#     makes the capture fail outright.
#   * **Never pass `--virtual-time-budget` for a page with a live poller** (the
#     run timeline polls `/feed`): Chrome waits for network idle and hangs until
#     killed. Chrome's default capture point is after `load`, which is enough
#     for the server-rendered pages.
#   * The board *does* need JavaScript (Mermaid draws the diagram), so it gets a
#     virtual-time budget — it has no poller of its own.
#   * `--user-data-dir` and `TMPDIR` must be writable, or Chrome cannot create
#     its headless profile container.
set -euo pipefail

BASE="${1:-http://127.0.0.1:3100}"
OUT="${2:-docs/images}"
RUN_ID="${3:-}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHROME="${CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
SHOT_DIR="$(mktemp -d)"
PROFILE="$SHOT_DIR/profile"
mkdir -p "$OUT" "$PROFILE"

if [ -z "$RUN_ID" ]; then
  RUN_ID="$(cd "$ROOT/runes_observer" && bin/rails runner 'print WorkflowRun.order(:id).last&.run_id' 2>/dev/null)"
fi
if [ -z "$RUN_ID" ]; then
  echo "no workflow run found — run scripts/demo_pipeline_run.rb first" >&2
  exit 1
fi
echo "run: $RUN_ID"

shoot() { # url, output name, extra chrome flags...
  local url="$1" name="$2"; shift 2
  TMPDIR="$SHOT_DIR" "$CHROME" --headless=new --no-sandbox --disable-gpu \
    --disable-dev-shm-usage --hide-scrollbars --no-first-run \
    --user-data-dir="$PROFILE" "$@" --screenshot="$SHOT_DIR/$name.png" \
    "$BASE/$url" >/dev/null 2>&1 || true
  if [ -f "$SHOT_DIR/$name.png" ]; then
    magick "$SHOT_DIR/$name.png" -resize 1680x -strip "$OUT/$name.png"
    echo "  wrote $OUT/$name.png ($(magick identify "$OUT/$name.png" | awk '{print $3}'))"
  else
    echo "  FAILED: $name" >&2
  fi
}

# Server-rendered pages: no JavaScript needed, and no virtual time budget (they poll).
shoot "runs/$RUN_ID" "run-timeline" --window-size=1680,1200
shoot "runs" "runs-index" --window-size=1680,1200
# The board needs Mermaid, which needs JavaScript; the budget makes the capture
# wait for the diagram instead of the poller (there is none on this page).
shoot "board" "board" --window-size=1680,2000 --virtual-time-budget=6000

rm -rf "$SHOT_DIR"
echo "done"
