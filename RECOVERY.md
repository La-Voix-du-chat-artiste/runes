# Recovery notes — 2026-09-07

This tree was reconstructed after the working directory was deleted
(twice) by a runaway test: `test_tui_publish_failure_rolls_back_goal_mode`
in `test/mode_commands_test.rb` created a `RunesTUI` with the DEFAULT
root (the project root) and its `ensure` block called
`FileUtils.remove_entry(root)` — deleting the repository mid-suite.

The guard is now in place: TUI tests pass an explicit tmpdir root, and
every cleanup is restricted to paths under `Dir.tmpdir`.

## What was reconstructed (from session context + your runic2 snapshot)

Everything needed to build and run the project, with ALL doc.md audit
fixes applied (D1–D11, M1–M11, W1–W6, L1–L7, R1–R5, T1–T9, S-*).

Test suite: **194+ runs, 0 failures, 1 skip** — the count grows as
regression tests are added (the skip is the key-gated live Synthetic
smoke test); see README/STATE for the current number.

## Permanently lost (not in context) — rebuild manually if needed

- `README.md`, `DEVELOPMENT_LOG.md`, `STATE.md`, `Runes.rtf`
- `ruby.wasm` (98 MB) — re-download to enable the real WASM backend
  (mock backend works without it; `RUNES_WASM=real` needs the file)
- `demo/*.rb` live demo scripts
- `docs/missions/*.json` / `docs/epics/*.md` original artifacts
- Original bodies of `test/dispatcher_integration_test.rb`,
  `test/mission_executor_test.rb`, `test/broker_roundtrip_test.rb`,
  most of `test/mode_commands_test.rb` (replaced by equivalent
  reconstructions covering the same behaviors)
- `config/.env` (if you had one: put provider keys there — they stay
  OUT of global ENV by design now, see S-R1)

## Run

    bundle install
    bundle exec rake test
    ./bin/runes-daemon        # agent (mock WASM backend)
    ./bin/runes               # TUI
    ./bin/runes-client "hi"   # CLI prompt
