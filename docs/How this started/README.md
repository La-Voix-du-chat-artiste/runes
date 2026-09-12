# How this started

The provenance of Runes, kept in the repo on purpose.

This is the unedited paper trail: three rounds of adversarial audit that the
project ran against itself, the recovery note from the one incident that cost
data, an architecture overview written while the transport seam was being
designed, and the document the whole thing grew out of.

| File | What it is |
|---|---|
| [`doc.md`](doc.md) | Round 3 audit — 49 findings, 22 of them security. The round that introduced the claim/started vocabulary the project later deleted. |
| [`doc4.md`](doc4.md) | Round 4 audit — 1235 lines. Includes the observatory's first real review. |
| [`doc5.md`](doc5.md) | Round 5 audit — 52 findings (3 critical, 15 high, 24 medium, 8 low, 2 medium-low) plus 25 proposed enhancements. Every finding was reproduced before it was fixed; Phases 18–19 and 22–29 of [`DEVELOPMENT_LOG.md`](../../DEVELOPMENT_LOG.md) are the work it produced. |
| [`RECOVERY.md`](RECOVERY.md) | The note written after the one incident that destroyed data, and what changed as a result. |
| [`Runes-MQTT-Overview.pdf`](Runes-MQTT-Overview.pdf) | The topic map and message flow, written when the fabric was still planned rather than shipped. |
| [`How it started.docx`](How%20it%20started.docx) | The origin document — the idea in its original words, before any of the code above. |

**Why publish these?** Because the audits name the flaws that the current code
was built to answer — an unauthenticated peer card, a token scan that is not a
sandbox, an observatory with no auth, at-least-once execution — and a project
that hides its own bug reports is asking you to trust its security posture on
vibes. The findings that are *still* open are listed honestly in
[`STATE.md`](../../STATE.md) and [`docs/WHY_RUNES.md`](../WHY_RUNES.md), and the
ones that were fixed each have a test behind them.

Two housekeeping notes: the text is unedited, including the parts that were
wrong about the code, and the files keep the names they were written with, so
`DEVELOPMENT_LOG.md` cites them by those names.
