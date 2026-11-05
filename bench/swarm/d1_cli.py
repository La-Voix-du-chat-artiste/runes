#!/usr/bin/env python3
"""Typed d1 decision CLI.

`system_one(state, questions, media:)` becomes one process:

    python3 bench/swarm/d1_cli.py --model LiquidAI/d1-2B-MLX-8bit \
      --state '<state>' --questions '<json>' [--media PATH]

The model does not sample and does not write prose. This script converts the
runner's question list into the d1 checkpoint's named-question mapping, calls
`model.system_one`, validates that every probability is in [0, 1], and prints
the verdict.v1 artifact on stdout as a JSON object with an `answers` list of
`{id, value, probability}` entries.
"""

import argparse
import json
import os
import pathlib
import sys

IMAGE_EXT = {".png", ".jpg", ".jpeg", ".gif", ".webp", ".bmp", ".tiff", ".tif"}
AUDIO_EXT = {".wav", ".mp3", ".m4a", ".flac", ".ogg", ".aac", ".opus", ".aiff", ".aif"}
VIDEO_EXT = {".mp4", ".mov", ".mkv", ".webm", ".avi", ".m4v"}


def fail(message: str) -> int:
    print(message, file=sys.stderr)
    return 2


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", default=os.environ.get("LFM3_D1_MODEL", "LiquidAI/d1-2B"))
    parser.add_argument("--state", required=True)
    parser.add_argument("--questions", required=True)
    parser.add_argument("--media")
    parser.add_argument("--verbose", action="store_true")
    return parser.parse_args()


def load_questions(raw: str):
    try:
        value = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise ValueError(f"--questions is not valid JSON: {exc}") from exc

    if isinstance(value, dict):
        entries = [
            {"id": str(key), "question": question}
            if not isinstance(question, dict)
            else {"id": str(key), **question}
            for key, question in value.items()
        ]
    elif isinstance(value, list):
        entries = value
    else:
        raise ValueError("--questions must be a JSON object or list")

    normalized = []
    for index, entry in enumerate(entries, start=1):
        if isinstance(entry, str):
            entry = {"id": f"q{index}", "question": entry}
        if not isinstance(entry, dict):
            raise ValueError(f"question {index} must be an object or string")
        identifier = str(entry.get("id") or f"q{index}")
        question = entry.get("question") or entry.get("prompt") or entry.get("text")
        if not question:
            raise ValueError(f"question {identifier!r} has no prompt")
        normalized.append(
            {
                "id": identifier,
                "question": str(question),
                "type": entry.get("type"),
                "options": entry.get("options") or entry.get("choices"),
            }
        )
    return normalized


def to_named(questions) -> dict:
    """The runner's question list -> the d1 checkpoint's named-question mapping."""
    named = {}
    for entry in questions:
        kind = (entry.get("type") or "").lower()
        text = entry["question"]
        options = entry.get("options")
        if kind == "choice" and options:
            named[entry["id"]] = {
                "type": "choice",
                "instructions": text,
                "criteria": {str(option): str(option) for option in options},
            }
        elif kind == "probability":
            named[entry["id"]] = {"type": "noul", "instructions": text}
        elif kind == "boolean":
            named[entry["id"]] = {
                "type": "noul",
                "instructions": text,
                "criteria": {"true": "yes", "false": "no"},
            }
        elif kind in ("string", "text"):
            named[entry["id"]] = {"type": "text", "instructions": text}
        elif kind == "number":
            named[entry["id"]] = {
                "type": "number",
                "instructions": text,
                "range": [0, 1000000],
            }
        else:
            named[entry["id"]] = {"type": "noul", "instructions": text}
    return named


def media_inputs(path: str):
    ext = pathlib.Path(path).suffix.lower()
    if ext in IMAGE_EXT:
        return [{"type": "image", "path": path}]
    if ext in AUDIO_EXT:
        return [{"type": "audio", "path": path}]
    if ext in VIDEO_EXT:
        return [{"type": "video", "path": path}]
    raise ValueError(f"unsupported media extension: {ext}")


def to_answer_entry(name: str, answer) -> dict:
    """One system_one answer -> the verdict.v1 `{id, value, probability}` entry."""
    if not isinstance(answer, dict):
        return {"id": name, "value": answer}
    kind = answer.get("type")
    if kind == "choice":
        return {
            "id": name,
            "value": answer.get("choice"),
            "probability": answer.get("confidence"),
        }
    if kind == "score":
        return {
            "id": name,
            "value": answer.get("score"),
            "probability": answer.get("confidence"),
        }
    if kind == "noul":
        probability = answer.get("noul")
        return {"id": name, "value": probability, "probability": probability}
    if kind == "text":
        return {"id": name, "value": answer.get("text")}
    if kind == "number":
        return {"id": name, "value": answer.get("number")}
    if kind == "date":
        return {"id": name, "value": answer.get("date")}
    value = answer.get("value", answer.get("text"))
    probability = answer.get("confidence", answer.get("probability"))
    return {"id": name, "value": value, "probability": probability}


def check_probabilities(entries) -> None:
    for entry in entries:
        probability = entry.get("probability")
        if probability is None:
            continue
        number = float(probability)
        if not 0.0 <= number <= 1.0:
            raise ValueError(f"question {entry['id']!r}: probability {number} outside [0, 1]")


def main() -> int:
    args = parse_args()
    try:
        questions = load_questions(args.questions)
    except ValueError as exc:
        return fail(str(exc))

    media = None
    if args.media:
        path = pathlib.Path(args.media).expanduser()
        if not path.is_file():
            return fail(f"media not found: {path}")
        try:
            media = media_inputs(str(path))
        except ValueError as exc:
            return fail(str(exc))

    try:
        from mlx_vlm.utils import load
    except ImportError as exc:
        return fail(f"mlx-vlm is not installed: {exc}")

    try:
        model, _processor = load(args.model)
        if not callable(getattr(model, "system_one", None)):
            return fail(
                f"{args.model} is not a d1 decision checkpoint "
                "(no system_one); use lfm3_cli.py for text models"
            )
        result = model.system_one(args.state, to_named(questions), media)
    except Exception as exc:  # noqa: BLE001 - report backend failures as infra
        return fail(f"d1 backend failed: {exc}")

    answers = result.get("answers") if isinstance(result, dict) else None
    if not isinstance(answers, dict) or not answers:
        return fail("d1 returned no answers")

    entries = [to_answer_entry(name, answer) for name, answer in answers.items()]
    try:
        check_probabilities(entries)
    except ValueError as exc:
        return fail(str(exc))

    artifact = {
        "schema": "verdict.v1",
        "answers": entries,
        "usage": result.get("usage") if isinstance(result, dict) else None,
    }
    print(json.dumps(artifact, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
