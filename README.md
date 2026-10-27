# CoreMLImageGen

A native SwiftUI Mac app that runs text-to-image models locally with Core ML. It is tuned for an **M1 Pro with 16 GB** of RAM.

- **Generate**: prompt, negative prompt, steps, guidance, seed, scheduler, live preview, and cancel. Every image is saved automatically.
- **Prompt enhancer** (⌘E): turns a short idea into a detailed prompt and negative prompt using Apple Intelligence, on device. See [Prompt enhancer](#prompt-enhancer).
- **Gallery**: every image in `~/Pictures/CoreMLImageGen`. Click one to restore its prompt and settings.
- **Models**: download Apple's pre-converted models from Hugging Face, import models you converted yourself, pick compute units per model, and delete models.
- Only **one model is resident at a time**. Switching models unloads the previous one first.

## Requirements
- macOS 15+, Apple silicon
- Xcode (this setup uses `/Applications/Xcode-beta.app`)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`

## Build & run
```bash
xcodegen generate
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  xcodebuild -project CoreMLImageGen.xcodeproj -scheme CoreMLImageGen \
  -destination 'platform=macOS' -derivedDataPath build build
open build/Build/Products/Debug/CoreMLImageGen.app
```
You can also open `CoreMLImageGen.xcodeproj` in Xcode and press Run. The `.xcodeproj` is generated, so edit `project.yml` instead.

Headless end-to-end check (Debug builds only). It downloads the model if needed, generates twice, and prints timings:
```bash
build/Build/Products/Debug/CoreMLImageGen.app/Contents/MacOS/CoreMLImageGen -smokeTest sd15-palettized -seed 42 -steps 25
```

## Models

| Catalog id | Model | Size | Compute | Status |
|---|---|---|---|---|
| `sd15-palettized` | SD 1.5, 6-bit | 1.6 GB | CPU + Neural Engine | ✅ |
| `sd15` | SD 1.5, fp16 (chunked UNet) | 2.6 GB | CPU + Neural Engine | ✅ |
| `sd21-base-palettized` | SD 2.1 base, 6-bit | 1.2 GB | CPU + Neural Engine | ✅ |
| `sdxl-base-mbp-4.5` | SDXL base, 4.5-bit mixed | 3.4 GB | CPU + GPU, reduced memory | ✅ |
| `zimage-turbo-coreai` | Z-Image-Turbo (Core AI, bf16) | ~19 GB | GPU | 🧪 no backend yet |
| `qwen-image-2.1-coreml` | Qwen-Image 2.1 (fp16) | 14.7 GB | GPU | 🧪 stretch goal |

Models are stored in `~/Library/Application Support/CoreMLImageGen/Models/<id>/`, each with a `model.json`. The catalog lives in `Core/catalog.json`. Adding an SD or SDXL repo there needs no code changes.

The **first load** of a model compiles it for this Mac's Neural Engine or GPU, which can take a few minutes. Later loads are fast.

### Measured on this M1 Pro (16 GB)
| Model | Steps | First load (compiles for the Neural Engine, once) | Per image | Notes |
|---|---|---|---|---|
| SD 1.5, 6-bit palettized | 25, DPM-Solver++ | ~4.6 min | **16 s** | Same seed gives identical pixels. App footprint ~185 MB (Neural Engine memory is counted separately) |

The download speed of the Hugging Face models depends on your connection; 1.6 GB took about 29 minutes here.

## Convert your own checkpoint
```bash
tools/convert/convert_sd.sh stable-diffusion-v1-5/stable-diffusion-v1-5 --nbits 6
tools/convert/convert_sd.sh stabilityai/stable-diffusion-xl-base-1.0 --xl --nbits 4
```
The first run creates a Python 3.11 venv in `tools/convert/.venv` and installs Apple's converter. The converter is pinned to the same commit as the app's Swift package. Output goes to `tools/convert/output/<repo>/Resources`. In the app, use **Models → Import Converted Model…** and choose that folder; the name, kind and resolution are pre-filled from the `model.json` the script writes.

- SD 1.x/2.x use `SPLIT_EINSUM_V2` attention, which suits the Neural Engine. SDXL uses `ORIGINAL`, which suits the GPU.
- RAM during conversion: SD 1.5 converts comfortably on 16 GB. SDXL swaps heavily and can take about an hour, so close other apps first.
- Gated or private repos need `huggingface-cli login` inside the venv first.

## Prompt enhancer
**Enhance** (⌘E, under the prompt) rewrites your idea with Apple's on-device Foundation Models. Nothing leaves the Mac. It needs macOS 26+ with Apple Intelligence turned on. Otherwise the button is disabled and shows the reason.

- **Adapts to the model.** SD 1.x/2.x get a compact, comma-separated prompt, because their text encoder reads only about 75 tokens. SDXL gets natural sentences plus style terms. Both also get a matching negative prompt.
- **Keeps trigger words.** Quoted text and capitalized phrases from your idea (e.g. a LoRA trigger like `Monet Style`, or `Tokyo`) are guaranteed to survive verbatim. If the language model drops one, it's put back at the front.
- **Variations and Undo.** Press Enhance again for another variation; it always starts from what *you* wrote. **Undo** restores your original text. Editing the prompt yourself makes that edit the new starting point.
- About 3–5 s per enhance on this M1 Pro. If the model returns a fragment, the enhancer retries once automatically.

Debug check: `…/CoreMLImageGen -enhanceTest "portrait of a knight, Monet Style"` prints the result for SD 1.x and SDXL.

## LoRAs
Core ML compiles weights into the model, so a LoRA can't be toggled at generation time. It is **fused into the base weights before conversion** instead:
```bash
# local file, optional strength (default 1.0); repeat --lora to stack several
tools/convert/convert_sd.sh stable-diffusion-v1-5/stable-diffusion-v1-5 --nbits 6 \
  --lora ~/Downloads/papercut.safetensors:0.8

# from Hugging Face: a repo id, or REPO::FILE for a specific file
tools/convert/convert_sd.sh stable-diffusion-v1-5/stable-diffusion-v1-5 --nbits 6 \
  --lora sayakpaul/sd-model-finetuned-lora-t4
```
- `tools/convert/fuse_lora.py` loads the base model and each LoRA through diffusers and PEFT. It accepts both diffusers and kohya/A1111 `.safetensors` LoRAs. It then fuses them at the given strengths and hands the result to Apple's converter.
- The import sheet pre-fills the LoRA names and strengths. The Generate and Models screens show which LoRAs a model has fused in.
- Every mix of LoRAs and strengths is its own model on disk (about 1.6 GB at 6-bit for SD 1.5). To try a different strength, convert again.
- Remember the LoRA's trigger words in your prompt.
- The LoRA must match the base model family (an SD 1.5 LoRA on an SD 1.5 base, an SDXL LoRA with `--xl`).

## Z-Image and Qwen-Image: status
- **Z-Image-Turbo** only exists as a community port to **Core AI**, the successor to Core ML in macOS 27 (`mlboydaisuke/Z-Image-Turbo-CoreAI`). Its weights are bf16: an 11 GB DiT plus a 7.3 GB Qwen3-4B encoder. On 16 GB it can only work if the encoder and DiT are loaded one after the other, and fp16 produces NaNs. Next step: a spike that measures it on this Mac, then either a `ZImageBackend` or our own palettized conversion.
- **Qwen-Image 2.1** has a community Core ML port (`devin-lai/Qwen-Image-2.1-Coreml`): 14.7 GB fp16, tested upstream on 32 GB only, with the text encoder not converted. Its weights are licensed for **non-commercial use only**. Fitting 16 GB needs about 4-bit transformer chunks plus a converted text encoder. This is a stretch goal.

Both appear in the Models list marked "Not supported yet". `Backends.make(for:)` in `Core/ImageBackend.swift` is where a new backend gets plugged in.

## Layout
```
App/            SwiftUI app, views, debug smoke test
Core/           request/record types, catalog, model store + HF downloader,
                generator (one resident model), image saver, backends/
tools/convert/  checkpoint -> Core ML conversion script
```
