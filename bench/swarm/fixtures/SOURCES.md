# Fixture sources

All 12 media files in this directory are **synthetic**, generated for this
benchmark on 2026-11-03 and released as **CC0-1.0** (see `provenance` in
`../cases.json`). No real person, document, voice or recording appears in
them. `index.json` pins each file's SHA-256, size, modality and the cases
that use it; `../export_fixtures.rb` verifies the hashes when copying them
out of the repo.

## Vision (PNG, generated programmatically)

| file | used by | content | gold |
|---|---|---|---|
| `chart-quarterly.png` | V1 | a bar chart with four labelled quarters; Q3 bar marked 25 | answer `25`, field `Q3=25` |
| `invoice-07.png` | V2 | a French invoice; total line reads `128,40 €` | answer `128,40 €`, field `total` |
| `screen-settings.png` | V3 | a settings screen; the primary button reads `Enregistrer` | answer `Enregistrer`, field `button` |
| `shapes-count.png` | V4 | geometric shapes; exactly three red circles | answer `3`, field `red_circles=3` |

## Audio (WAV, 16-bit mono 16 kHz, synthesized)

| file | used by | content | gold |
|---|---|---|---|
| `asr-order.wav` | A1 | spoken English: "The order number is four two seven one." | answer `4271`, transcript |
| `fr-meeting.wav` | A2 | spoken French: "La réunion est déplacée à quatorze heures trente." | answer `14 h 30`, transcript |
| `sound-alarm.wav` | A3 | three short high beeps (no speech) | answer `alarme`, event transcript |
| `spoken-request.wav` | A4 | spoken French request: "ouvrir une facture" | answer `ouvrir une facture`, intent `open_invoice` |

## Audio-video (MP4, synthetic frames + synthesized speech)

| file | used by | content | gold |
|---|---|---|---|
| `av-speech-referent.mp4` | AV1 | speech "The red square is on the left." over frames showing a red square left, blue circle right | answer `à gauche` |
| `av-contradiction.mp4` | AV2 | speech "The circle is blue." over frames showing a red circle and a blue rectangle | answer `non, contradiction`, `contradiction: true` |

`av-frame-1.png` / `av-frame-2.png` are the extracted frames of the AV
fixtures, kept for debugging perception anchors; no case reads them
directly.

## Regenerating

The fixtures are frozen; do not regenerate them in place. To rebuild an
equivalent set, generate the same content described above and update
`index.json` with `ruby ../export_fixtures.rb --out <dir>` — the exporter
writes a fresh index and refuses to export files whose hash drifted from
the committed one.
