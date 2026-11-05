#!/usr/bin/env python3
"""stdin -> LFM3-1.7B text adapter.

The Ruby adapter builds argv explicitly and writes the prompt to stdin; this
script never interpolates model output into a shell. Backends are imported
lazily so `--help` works on a machine without mlx-vlm or transformers.

    python3 bench/swarm/lfm3_cli.py \
      --model LiquidAI/LFM3-1.7B \
      --max-tokens 320 --temperature 0.1 --top-k 50 --repetition-penalty 1.1
"""

import argparse
import os
import pathlib
import sys


def fail(message: str) -> int:
    print(message, file=sys.stderr)
    return 2


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", default=os.environ.get("LFM3_MODEL"))
    parser.add_argument("--python", default=os.environ.get("LFM3_PYTHON", "python3"))
    parser.add_argument("--max-tokens", type=int, default=320)
    parser.add_argument("--temperature", type=float, default=0.1)
    parser.add_argument("--top-p", type=float, default=None)
    parser.add_argument("--top-k", type=int, default=50)
    parser.add_argument("--repetition-penalty", type=float, default=1.1)
    parser.add_argument("--enable-thinking", action="store_true")
    parser.add_argument(
        "--backend", choices=("auto", "mlx_vlm", "transformers"), default="auto"
    )
    parser.add_argument("--verbose", action="store_true")
    return parser.parse_args()


def resolve_model(value: str) -> str:
    model = pathlib.Path(value).expanduser()
    if model.exists():
        return str(model)
    if "/" in value and not pathlib.Path(value).is_absolute():
        # A Hugging Face repository id, not a local path.
        return value
    return str(model)


def generate_mlx(args: argparse.Namespace, prompt: str) -> str:
    try:
        from mlx_vlm import generate, load
    except ImportError as exc:  # pragma: no cover - depends on the machine
        raise RuntimeError(f"mlx-vlm is not installed: {exc}") from exc

    model, processor = load(args.model)
    kwargs = {
        "max_tokens": args.max_tokens,
        "temperature": args.temperature,
        "top_k": args.top_k,
        "repetition_penalty": args.repetition_penalty,
        "verbose": args.verbose,
    }
    if args.top_p is not None:
        kwargs["top_p"] = args.top_p
    if args.enable_thinking:
        kwargs["enable_thinking"] = True

    # generate() does not apply the chat template; do it here so the model
    # sees a proper user/assistant turn.
    from mlx_vlm.prompt_utils import apply_chat_template

    prompt = apply_chat_template(processor, model.config, prompt)
    result = generate(model, processor, prompt, **kwargs)
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
        from transformers import AutoModelForCausalLM, AutoTokenizer
    except ImportError as exc:  # pragma: no cover - depends on the machine
        raise RuntimeError(f"transformers/torch are not installed: {exc}") from exc

    tokenizer = AutoTokenizer.from_pretrained(args.model, trust_remote_code=True)
    model = AutoModelForCausalLM.from_pretrained(
        args.model,
        torch_dtype="auto",
        device_map="auto",
        trust_remote_code=True,
    )
    inputs = tokenizer(prompt, return_tensors="pt").to(model.device)
    kwargs = {
        "max_new_tokens": args.max_tokens,
        "do_sample": True,
        "temperature": max(args.temperature, 1e-5),
        "top_k": args.top_k,
        "repetition_penalty": args.repetition_penalty,
    }
    if args.top_p is not None:
        kwargs["top_p"] = args.top_p
    with torch.no_grad():
        output = model.generate(**inputs, **kwargs)
    decoded = tokenizer.decode(output[0][inputs["input_ids"].shape[-1] :], skip_special_tokens=True)
    return decoded.strip()


def main() -> int:
    args = parse_args()
    if not args.model:
        return fail("missing --model (or LFM3_MODEL)")
    if args.max_tokens <= 0:
        return fail("--max-tokens must be positive")

    prompt = sys.stdin.read()
    if not prompt.strip():
        return fail("empty prompt on stdin")

    args.model = resolve_model(args.model)
    backend = args.backend
    if backend == "auto":
        try:
            import mlx_vlm  # noqa: F401

            backend = "mlx_vlm"
        except ImportError:
            backend = "transformers"

    try:
        answer = (
            generate_mlx(args, prompt)
            if backend == "mlx_vlm"
            else generate_transformers(args, prompt)
        )
    except Exception as exc:  # noqa: BLE001 - report backend failures as infra
        return fail(f"{backend} backend failed: {exc}")

    if not answer:
        return fail("model produced empty stdout")
    print(answer)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
