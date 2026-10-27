#!/usr/bin/env bash
# Convert a Hugging Face Stable Diffusion (1.x/2.x) or SDXL checkpoint to Core ML
# resources the app can import (Models > Import Converted Model…).
#
#   tools/convert/convert_sd.sh <hf-repo-id> [--xl] [--nbits 6] [--lora SOURCE[:SCALE]]... [--name "My model"] [--out DIR]
#
# --lora fuses a LoRA into the weights before conversion (repeatable). SOURCE is a local
# .safetensors file, a Hugging Face repo id, or REPO::FILE. SCALE defaults to 1.0.
#
# Examples:
#   tools/convert/convert_sd.sh stable-diffusion-v1-5/stable-diffusion-v1-5 --nbits 6
#   tools/convert/convert_sd.sh stable-diffusion-v1-5/stable-diffusion-v1-5 --nbits 6 --lora ~/Downloads/papercut.safetensors:0.8
#   tools/convert/convert_sd.sh stabilityai/stable-diffusion-xl-base-1.0 --xl --nbits 4
#
# On a 16 GB Mac, SD 1.5 converts in ~10-20 min. SDXL swaps heavily and can take an hour;
# close other apps first.
set -euo pipefail

usage() { sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }

[[ $# -ge 1 ]] || usage
REPO="$1"; shift
XL=0
NBITS=""
NAME=""
OUT=""
LORAS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --xl) XL=1 ;;
    --nbits) NBITS="$2"; shift ;;
    --lora) LORAS+=("$2"); shift ;;
    --name) NAME="$2"; shift ;;
    --out) OUT="$2"; shift ;;
    -h|--help) usage ;;
    *) echo "Unknown option: $1" >&2; usage ;;
  esac
  shift
done

HERE="$(cd "$(dirname "$0")" && pwd)"
VENV="$HERE/.venv"
SLUG="$(echo "$REPO" | tr '/' '_')"
[[ ${#LORAS[@]} -gt 0 ]] && SLUG="$SLUG-lora$(printf '%s' "${LORAS[@]}" | shasum | cut -c1-8)"
OUT="${OUT:-$HERE/output/$SLUG${NBITS:+-${NBITS}bit}}"

if [[ ! -x "$VENV/bin/python" ]]; then
  echo "Creating venv in $VENV (Python 3.11)…"
  python3.11 -m venv "$VENV"
  "$VENV/bin/pip" install --upgrade pip
  "$VENV/bin/pip" install -r "$HERE/requirements.txt"
fi

MODEL_VERSION="$REPO"
FUSED=""
if [[ ${#LORAS[@]} -gt 0 ]]; then
  FUSED="$OUT/fused-base"
  LORA_ARGS=()
  for l in "${LORAS[@]}"; do LORA_ARGS+=(--lora "$l"); done
  "$VENV/bin/python" "$HERE/fuse_lora.py" --base "$REPO" "${LORA_ARGS[@]}" --out "$FUSED"
  MODEL_VERSION="$FUSED"
fi

ARGS=(
  --model-version "$MODEL_VERSION"
  --convert-unet --convert-text-encoder --convert-vae-decoder
  --bundle-resources-for-swift-cli
  -o "$OUT"
)
if [[ $XL -eq 1 ]]; then
  # SDXL: GPU-friendly attention; no chunking needed on macOS.
  ARGS+=(--xl-version --attention-implementation ORIGINAL)
  KIND=sdxl; RES=1024
else
  # SD 1.x/2.x: Neural Engine-friendly attention.
  ARGS+=(--attention-implementation SPLIT_EINSUM_V2)
  KIND=sd; RES=512
fi
[[ -n "$NBITS" ]] && ARGS+=(--quantize-nbits "$NBITS")

echo "Converting $MODEL_VERSION -> $OUT"
"$VENV/bin/python" -m python_coreml_stable_diffusion.torch2coreml "${ARGS[@]}"

RESOURCES="$OUT/Resources"
# model.json pre-fills the app's import sheet, including any fused LoRAs.
"$VENV/bin/python" - "$RESOURCES/model.json" "$REPO" "$KIND" "$RES" "$NBITS" "$NAME" "$FUSED" <<'PY'
import json, os, sys
out, repo, kind, res, nbits, name, fused = sys.argv[1:]
loras = json.load(open(os.path.join(fused, "loras.json"))) if fused else []
if not name:
    name = repo.split("/")[-1]
    if loras:
        name += " + " + ", ".join(f"{l['name']} {l['scale']:g}" for l in loras)
    if nbits:
        name += f" ({nbits}-bit)"
json.dump({"name": name, "kind": kind, "resolution": int(res), "loras": loras}, open(out, "w"), indent=2)
PY

# The fused diffusers copy is only an intermediate (2-7 GB).
[[ -n "$FUSED" ]] && rm -rf "$FUSED"

echo
echo "Done. In the app: Models > Import Converted Model… and choose:"
echo "  $RESOURCES"
