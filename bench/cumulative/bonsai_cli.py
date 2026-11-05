#!/usr/bin/env python3
"""stdin -> mlx_vlm.generate adapter for the cumulative benchmark.

The benchmark never interpolates model output into a shell. This script does
the same for the model command: argv is a list, stdin is the prompt, stdout is
the answer.

    ruby bench/cumulative/runner.rb \
      --arm 2x-adaptive \
      --command "bench/cumulative/bonsai_cli.py --model $BONSAI_MODEL"

Set BONSAI_PYTHON to the interpreter that has mlx-vlm installed. The default
sampler matches the Bonsai model card's non-thinking recommendation; pass the
flags explicitly because mlx_vlm.generate defaults to greedy decoding.
"""

import argparse
import os
import pathlib
import subprocess
import sys


def fail(message: str) -> int:
    print(message, file=sys.stderr)
    return 2


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", default=os.environ.get("BONSAI_MODEL"))
    parser.add_argument("--python", default=os.environ.get("BONSAI_PYTHON", "python3"))
    parser.add_argument("--max-tokens", type=int, default=320)
    parser.add_argument("--temperature", type=float, default=0.7)
    parser.add_argument("--top-p", type=float, default=0.8)
    parser.add_argument("--top-k", type=int, default=20)
    parser.add_argument("--presence-penalty", type=float, default=1.5)
    parser.add_argument("--verbose", action="store_true")
    args = parser.parse_args()

    if not args.model:
        return fail("missing --model (or BONSAI_MODEL)")
    if args.max_tokens <= 0:
        return fail("--max-tokens must be positive")

    model = pathlib.Path(args.model).expanduser()
    if not model.exists():
        return fail(f"model path not found: {model}")
    if model.is_dir() and not (
        (model / "model.safetensors").is_file()
        or (model / "config.json").is_file()
        or (model / "model.safetensors.index.json").is_file()
    ):
        return fail(f"model directory has no MLX/Transformers weights: {model}")

    prompt = sys.stdin.read()
    if not prompt.strip():
        return fail("empty prompt on stdin")

    command = [
        args.python,
        "-m",
        "mlx_vlm.generate",
        "--model",
        str(model),
        "--prompt",
        prompt,
        "--max-tokens",
        str(args.max_tokens),
        "--temperature",
        str(args.temperature),
        "--top-p",
        str(args.top_p),
        "--top-k",
        str(args.top_k),
        "--presence-penalty",
        str(args.presence_penalty),
    ]
    if not args.verbose:
        command.append("--no-verbose")

    try:
        result = subprocess.run(command, capture_output=True, text=True)
    except FileNotFoundError:
        return fail(f"python interpreter not found: {args.python}")

    if result.returncode != 0:
        sys.stderr.write(result.stderr)
        return result.returncode

    answer = result.stdout.strip()
    if not answer:
        return fail("mlx_vlm.generate produced empty stdout")
    print(answer)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
