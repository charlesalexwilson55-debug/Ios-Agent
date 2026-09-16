"""Convert a peft/Unsloth LoRA adapter into the format mlx-swift-lm loads.

Why this exists: mlx-swift-lm can load and hot-swap a LoRA adapter at runtime
(LoRAContainer.from(directory:) then load(into:)). That means a fine-tune can
ship as a ~50-150MB adapter folder dropped beside the base model, instead of a
second 4.6GB copy of the weights. It also avoids needing a Mac, because
`mlx_lm.convert` only runs on Apple silicon and this script runs anywhere.

The two formats differ in three ways, all handled below:

  1. File name:  adapter_model.safetensors  ->  adapters.safetensors
  2. Key names:  base_model.model.model.layers.N.self_attn.q_proj.lora_A.weight
                 ->  model.layers.N.self_attn.q_proj.lora_a
  3. Shapes:     peft stores lora_A as [r, in] and lora_B as [out, r];
                 MLX expects lora_a as [in, r] and lora_b as [r, out].
                 Both are transposed.

Config is rewritten from peft's {r, lora_alpha, target_modules} to MLX's
{fine_tune_type, num_layers, lora_parameters: {rank, scale, dropout, keys}},
where scale = lora_alpha / r.

HONEST CAVEAT: this was written against the documented formats on both sides
but has not been run against a real trained adapter, because producing one
needs a GPU this project does not have. Treat the first run as something to
verify, not to trust. The script prints every key it rewrites and refuses to
write a partial result, so a mismatch is loud rather than silent. If the app
loads the adapter and output degrades rather than improves, suspect the
transposes first.

Usage:
    python convert_adapter.py --adapter conduit-lora --out conduit-lora-mlx
"""
from __future__ import annotations

import argparse
import json
import re
import shutil
from pathlib import Path

# base_model.model.model.layers.0.self_attn.q_proj.lora_A.weight
PEFT_KEY = re.compile(
    r"^base_model\.model\.(?P<path>model\.layers\.\d+\..*?)\.lora_(?P<side>[AB])\.weight$"
)


def convert_key(key: str) -> str | None:
    match = PEFT_KEY.match(key)
    if not match:
        return None
    side = "lora_a" if match.group("side") == "A" else "lora_b"
    return f"{match.group('path')}.{side}"


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--adapter", required=True, help="peft/Unsloth adapter directory")
    parser.add_argument("--out", required=True, help="output directory for the MLX adapter")
    parser.add_argument("--dropout", type=float, default=0.05)
    args = parser.parse_args()

    try:
        import numpy as np
        from safetensors.numpy import load_file, save_file
    except ImportError:
        raise SystemExit(
            "Needs numpy and safetensors:\n    pip install numpy safetensors"
        )

    adapter_dir = Path(args.adapter)
    out_dir = Path(args.out)

    config_path = adapter_dir / "adapter_config.json"
    if not config_path.exists():
        raise SystemExit(f"No adapter_config.json in {adapter_dir}")

    weights_path = adapter_dir / "adapter_model.safetensors"
    if not weights_path.exists():
        raise SystemExit(
            f"No adapter_model.safetensors in {adapter_dir}.\n"
            "If training saved a .bin instead, load it with torch and re-save as safetensors."
        )

    peft_config = json.loads(config_path.read_text(encoding="utf-8"))
    rank = peft_config.get("r")
    alpha = peft_config.get("lora_alpha")
    if rank is None or alpha is None:
        raise SystemExit("adapter_config.json is missing r or lora_alpha")

    tensors = load_file(str(weights_path))
    converted: dict = {}
    skipped: list[str] = []
    layer_indices: set[int] = set()

    for key, value in tensors.items():
        new_key = convert_key(key)
        if new_key is None:
            skipped.append(key)
            continue
        # Both sides transpose; see the module docstring.
        converted[new_key] = np.ascontiguousarray(value.T)
        layer_match = re.search(r"model\.layers\.(\d+)\.", new_key)
        if layer_match:
            layer_indices.add(int(layer_match.group(1)))

    if not converted:
        raise SystemExit(
            "No LoRA tensors were recognised. Keys looked like:\n  "
            + "\n  ".join(list(tensors)[:5])
            + "\nThe naming convention may have changed; update PEFT_KEY."
        )

    # Each targeted projection must have both halves, or MLX will load a
    # broken module. Better to fail here than to ship an adapter that silently
    # applies half a transform.
    stems = {key.rsplit(".", 1)[0] for key in converted}
    incomplete = [
        stem for stem in stems
        if f"{stem}.lora_a" not in converted or f"{stem}.lora_b" not in converted
    ]
    if incomplete:
        raise SystemExit(
            f"{len(incomplete)} projection(s) are missing an A or B half, e.g. "
            f"{incomplete[:3]}. Refusing to write a partial adapter."
        )

    # MLX keys are the projection suffixes, e.g. self_attn.q_proj.
    keys = sorted({
        re.sub(r"^model\.layers\.\d+\.", "", stem) for stem in stems
    })

    out_dir.mkdir(parents=True, exist_ok=True)
    save_file(converted, str(out_dir / "adapters.safetensors"))

    mlx_config = {
        "fine_tune_type": "lora",
        "num_layers": len(layer_indices),
        "lora_parameters": {
            "rank": rank,
            "scale": alpha / rank,
            "dropout": args.dropout,
            "keys": keys,
        },
    }
    (out_dir / "adapter_config.json").write_text(
        json.dumps(mlx_config, indent=2) + "\n", encoding="utf-8"
    )

    # Carry the tokenizer over if it was saved; harmless if unused, and it
    # makes the folder self-describing.
    for name in ("tokenizer.json", "tokenizer_config.json", "special_tokens_map.json"):
        source = adapter_dir / name
        if source.exists():
            shutil.copy2(source, out_dir / name)

    print(f"Converted {len(converted)} tensors across {len(layer_indices)} layers")
    print(f"  rank={rank}  scale={alpha / rank}")
    print(f"  keys={keys}")
    if skipped:
        print(f"  skipped {len(skipped)} non-LoRA tensors "
              f"(expected: {skipped[:3]}{'...' if len(skipped) > 3 else ''})")
    print(f"\nWrote {out_dir}/")
    print("  adapters.safetensors")
    print("  adapter_config.json")
    print("\nCopy this folder onto the phone (Files app, into Conduit's folder), then pick it")
    print("in Conduit under Model > LoRA adapter. Reselect the model afterwards.")


if __name__ == "__main__":
    main()
