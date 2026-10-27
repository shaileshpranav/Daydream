"""Fuse one or more LoRAs into a Stable Diffusion / SDXL checkpoint.

Core ML models have their weights compiled in, so a LoRA can't be switched on at
runtime: it has to be merged into the base weights before conversion. This writes
a diffusers folder that torch2coreml loads like any Hugging Face model id
(fp16 safetensors variant, which is what its get_pipeline() asks for).

  python fuse_lora.py --base stable-diffusion-v1-5/stable-diffusion-v1-5 \
      --lora ~/Downloads/papercut.safetensors:0.8 \
      --lora some-user/some-lora-repo::lora.safetensors:0.5 \
      --out output/fused

LoRA spec: SOURCE[:SCALE] where SOURCE is a local .safetensors file, a local
diffusers LoRA folder, a Hugging Face repo id, or REPO::FILE for a specific file
in a repo. SCALE defaults to 1.0.
"""
import argparse
import json
import os

import torch
from diffusers import DiffusionPipeline


def parse_spec(spec):
    source, scale = spec, 1.0
    head, sep, tail = spec.rpartition(":")
    if sep and head:
        try:
            scale = float(tail)
            source = head
        except ValueError:
            pass
    return os.path.expanduser(source), scale


def load_kwargs(source):
    """Turn a LoRA source into (path_or_repo, kwargs) for load_lora_weights."""
    if os.path.isfile(source):
        path = os.path.abspath(source)
        return os.path.dirname(path), {"weight_name": os.path.basename(path)}
    if "::" in source:
        repo, weight_name = source.split("::", 1)
        return repo, {"weight_name": weight_name}
    return source, {}


def load_base(base):
    # Prefer the fp16 safetensors variant; fall back to full-precision files, then to
    # older .bin checkpoints. Everything is loaded as fp16 either way.
    attempts = [dict(variant="fp16", use_safetensors=True), dict(use_safetensors=True), dict()]
    for i, extra in enumerate(attempts):
        try:
            return DiffusionPipeline.from_pretrained(base, torch_dtype=torch.float16, **extra)
        except (OSError, ValueError):
            if i == len(attempts) - 1:
                raise


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--base", required=True, help="Base model: Hugging Face repo id or local diffusers folder")
    parser.add_argument("--lora", action="append", required=True, metavar="SOURCE[:SCALE]")
    parser.add_argument("--out", required=True)
    args = parser.parse_args()

    print(f"Loading base {args.base}")
    pipe = load_base(args.base)

    names, scales, fused = [], [], []
    for i, spec in enumerate(args.lora):
        source, scale = parse_spec(spec)
        path, kwargs = load_kwargs(source)
        name = f"lora{i}"
        print(f"Loading LoRA {source} (scale {scale})")
        pipe.load_lora_weights(path, adapter_name=name, **kwargs)
        names.append(name)
        scales.append(scale)
        label = os.path.splitext(os.path.basename(kwargs.get("weight_name", source)))[0]
        fused.append({"name": label, "source": source, "scale": scale})

    pipe.set_adapters(names, adapter_weights=scales)
    pipe.fuse_lora(adapter_names=names, lora_scale=1.0)
    pipe.unload_lora_weights()

    print(f"Saving fused model to {args.out}")
    pipe.save_pretrained(args.out, variant="fp16", safe_serialization=True)
    with open(os.path.join(args.out, "loras.json"), "w") as f:
        json.dump(fused, f, indent=2)


if __name__ == "__main__":
    main()
