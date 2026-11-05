#!/usr/bin/env python3
"""One media artifact -> LFM3 perception text.

The Ruby media adapters call this script with exactly one `--input`. It
selects the family-specific checkpoint, builds a perception prompt, and
writes text to stdout. Anchors and provenance are added by the Ruby adapter,
not trusted from the model.
"""

import argparse
import os
import pathlib
import sys

FAMILIES = {
    "vision": {
        "model": os.environ.get("LFM3_VL_MODEL", "LiquidAI/LFM3-VL-2B"),
        "prompt": "Describe this image, document, chart or screen. Locate the relevant objects and cite page/box anchors.",
    },
    "audio": {
        "model": os.environ.get("LFM3_AUDIO_MODEL", "LiquidAI/LFM3-Audio-2B"),
        "prompt": "Transcribe the speech, identify the language and sound events, and cite time anchors.",
    },
    "omni": {
        "model": os.environ.get("LFM3_OMNI_MODEL", "LiquidAI/LFM3-Omni-2B"),
        "prompt": "Read the audio and video jointly. Align speech to frames and cite time/frame anchors.",
    },
}


def fail(message: str) -> int:
    print(message, file=sys.stderr)
    return 2


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--family", choices=tuple(FAMILIES), required=True)
    parser.add_argument("--model")
    parser.add_argument("--input", required=True)
    parser.add_argument("--max-tokens", type=int, default=512)
    parser.add_argument("--chunk-offset", type=int, default=None)
    parser.add_argument("--chunk-length", type=int, default=None)
    parser.add_argument(
        "--backend", choices=("auto", "mlx_vlm", "transformers"), default="auto"
    )
    parser.add_argument("--verbose", action="store_true")
    return parser.parse_args()


def build_prompt(args: argparse.Namespace) -> str:
    family = FAMILIES[args.family]
    chunk = ""
    if args.chunk_offset is not None or args.chunk_length is not None:
        chunk = (
            f"\nChunk: offset={args.chunk_offset or 0} "
            f"length={args.chunk_length or 0}"
        )
    # No media placeholder in the text: mlx-vlm's chat template inserts
    # <|image|>/<|audio|>/<|video|> itself from the image/audio/video kwargs.
    return (
        f"You are a {args.family} perception role. {family['prompt']}\n"
        f"Return the perception as plain text, one observation per line, each "
        f"with its anchor in parentheses, e.g. `Q3 bar reads 25 (image:1)`. "
        f"Do not return JSON, do not answer the task or judge it.\n"
        f"\nMedia: attached.{chunk}\n"
    )


IMAGE_EXT = {".png", ".jpg", ".jpeg", ".webp", ".bmp"}
AUDIO_EXT = {".wav", ".mp3", ".ogg", ".flac", ".m4a"}
VIDEO_EXT = {".mp4", ".webm", ".mov", ".mkv", ".avi"}


def media_kwargs(path: str) -> dict:
    ext = pathlib.Path(path).suffix.lower()
    if ext in AUDIO_EXT:
        return {"audio": [path]}
    if ext in VIDEO_EXT:
        # An AV file carries both tracks; the omni model needs the video
        # frames and the audio track as separate inputs.
        return {"video": [path], "audio": [path]}
    return {"image": [path]}


def generate_mlx(args: argparse.Namespace, prompt: str) -> str:
    try:
        from mlx_vlm import generate, load
        from mlx_vlm.prompt_utils import apply_chat_template
    except ImportError as exc:  # pragma: no cover
        raise RuntimeError(f"mlx-vlm is not installed: {exc}") from exc

    model, processor = load(args.model)
    kwargs = media_kwargs(args.input)
    images = kwargs.get("image")
    audios = kwargs.get("audio")
    videos = kwargs.get("video")
    # generate() does not apply the chat template; do it here so the model
    # sees a proper user/assistant turn with the media placeholder inserted.
    templated = apply_chat_template(
        processor,
        model.config,
        prompt,
        num_images=len(images) if images else 0,
        num_audios=len(audios) if audios else 0,
        **({"video": videos} if videos else {}),
    )
    result = generate(
        model,
        processor,
        templated,
        **kwargs,
        max_tokens=args.max_tokens,
        verbose=args.verbose,
    )
    return unwrap(result)


def unwrap(result) -> str:
    # mlx-vlm >= 0.7 returns a GenerationResult; older versions a str or tuple.
    if hasattr(result, "text"):
        result = result.text
    elif isinstance(result, tuple):
        result = result[0]
    return str(result).strip()


def generate_transformers(args: argparse.Namespace, prompt: str) -> str:
    try:
        import torch
        from transformers import AutoProcessor, AutoModelForVision2Seq
    except ImportError as exc:  # pragma: no cover
        raise RuntimeError(f"transformers/torch are not installed: {exc}") from exc

    processor = AutoProcessor.from_pretrained(args.model, trust_remote_code=True)
    model = AutoModelForVision2Seq.from_pretrained(
        args.model, torch_dtype="auto", device_map="auto", trust_remote_code=True
    )
    inputs = processor(text=prompt, images=[args.input], return_tensors="pt").to(model.device)
    with torch.no_grad():
        output = model.generate(**inputs, max_new_tokens=args.max_tokens)
    return processor.batch_decode(output, skip_special_tokens=True)[0].strip()


def main() -> int:
    args = parse_args()
    media = pathlib.Path(args.input).expanduser()
    if not media.is_file():
        return fail(f"input not found: {media}")
    if args.max_tokens <= 0:
        return fail("--max-tokens must be positive")

    args.model = args.model or FAMILIES[args.family]["model"]
    backend = args.backend
    if backend == "auto":
        try:
            import mlx_vlm  # noqa: F401

            backend = "mlx_vlm"
        except ImportError:
            backend = "transformers"

    # The Ruby adapter pipes its perception prompt on stdin; prefer it when
    # present so there is one prompt source of truth.
    stdin_prompt = sys.stdin.read() if not sys.stdin.isatty() else ""
    prompt = stdin_prompt.strip() or build_prompt(args)
    try:
        answer = (
            generate_mlx(args, prompt)
            if backend == "mlx_vlm"
            else generate_transformers(args, prompt)
        )
    except Exception as exc:  # noqa: BLE001
        return fail(f"{backend} backend failed: {exc}")

    if not answer:
        return fail("model produced empty stdout")
    print(answer)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
