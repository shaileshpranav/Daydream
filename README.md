# CoreMLImageGen

A native SwiftUI Mac app that runs text-to-image models locally. It is tuned for an **M1 Pro with 16 GB** of RAM. It has two backends: **Core ML** for Stable Diffusion 1.5/2.1/XL (Neural Engine friendly), and **MLX** for newer quantized models such as Z-Image, FLUX.2 and Qwen-Image (see [MLX models](#mlx-models-z-image-flux2-qwen-image)).

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
| `mlx-flux2-klein-4b-q4` | FLUX.2 Klein 4B, 4-bit (MLX) | 4.6 GB | GPU, float16 | ✅ needs MLX runtime |
| `mlx-z-image-turbo-q4` | Z-Image Turbo, 4-bit (MLX) | 5.9 GB | GPU, float16 | ✅ needs MLX runtime |
| `mlx-qwen-image-2.1-turbo-q4` | Qwen-Image 2.1 Turbo, 4-bit (MLX) | 10 GB | GPU, float16 | ✅ needs MLX runtime; tight on 16 GB |

Models are stored in `~/Library/Application Support/CoreMLImageGen/Models/<id>/`, each with a `model.json`. The catalog lives in `Core/catalog.json`. Adding an SD or SDXL repo there needs no code changes.

The **first load** of a model compiles it for this Mac's Neural Engine or GPU, which can take a few minutes. Later loads are fast.

### Measured on this M1 Pro (16 GB)
| Model | Steps | First load (compiles for the Neural Engine, once) | Per image | Notes |
|---|---|---|---|---|
| SD 1.5, 6-bit palettized | 25, DPM-Solver++ | ~4.6 min | **16 s** | Same seed gives identical pixels. App footprint ~185 MB (Neural Engine memory is counted separately) |
| Z-Image Turbo, 4-bit (MLX) | 9 | ~11 s | **170 s** at 1024×1024 | About 18 s per step |
| FLUX.2 Klein 4B, 4-bit (MLX) | 4 | ~6 s (no compile step) | **82 s** at 1024×1024 | About 16 s per step plus text encoding and decode. Same seed gives identical pixels. Smaller aspect sizes are proportionally faster |

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

## MLX models (Z-Image, FLUX.2, Qwen-Image)
Newer diffusion transformers have no practical Core ML conversion that fits 16 GB, so the app runs them with **MLX** through [mflux](https://github.com/mflux-community/mflux). mflux offers pre-quantized 3–8-bit weights for most current open image models.

**Setup:** go to **Models → MLX runtime → Install**. This creates a Python venv in `~/Library/Application Support/CoreMLImageGen/MLX` with a pinned `mflux` (and MLX). It needs Python 3.11+ from Homebrew (`brew install python@3.12`). Then download an MLX model like any other.

**How it runs:**
- `Core/Backends/mlx_worker.py` is a long-lived Python worker. The app talks to it in JSON lines (`MLXBackend.swift`), and the model stays loaded between images.
- Unloading or switching models **terminates the worker**, which reliably returns all of its memory to the system.
- It uses float16 compute, because M1 GPUs have no native bfloat16. mflux measured this as 22–27% faster on M1.
- Cancel stops at the next denoising step.
- If the worker dies (most likely out of memory), the app says so. mflux's output and tracebacks go to `~/Library/Application Support/CoreMLImageGen/MLX/worker.log` (**Models → MLX runtime → Log**).

**What differs from Core ML models:**
- **Any size:** pick an aspect ratio (1:1, 3:4, 4:3, 16:9, 9:16). The pixel count stays about the model's base resolution squared.
- **Only compatible LoRAs:** each LoRA's base model is read from its `.safetensors` header. That's the `ss_base_model_version` / `modelspec.architecture` metadata, or for files without it, the layer names and sizes (Z-Image, FLUX.2 Klein 4B/9B, FLUX.1, SD/SDXL). Only LoRAs for the selected model can be added. The Loras-folder menu lists the others greyed out, with what they're for. Hugging Face repos are checked by fetching only the header. Switching models removes LoRAs for the old one. Qwen-Image LoRAs are only recognized from their metadata.
- **Use Recommended** (Settings section): resets steps, guidance and (for Core ML) the scheduler to what the selected model is tuned for. It shows "In use" when they already match.
- **Model defaults:** picking a model sets its steps and guidance (FLUX.2 Klein: 4 steps; Z-Image Turbo: 9 steps, guidance 0; Qwen-Image 2.1 Turbo: 8). FLUX.2 Klein takes no negative prompt, so that field hides.
- **LoRAs without conversion:** put `.safetensors` files in `~/Library/Application Support/CoreMLImageGen/Models/Loras` (subfolders are fine). They're listed under **Add from Loras Folder** in the Generate screen's LoRA section, which also has **Rescan Folder** and **Show Loras Folder in Finder**. You can also add any file or a Hugging Face repo, then set its strength with a slider. LoRAs load with the model: changing them reloads the weights on the next generate, which takes seconds to a minute rather than an hour of conversion. The LoRA must match the model family.
- **No live preview** for MLX models; you see step progress.

**Adding another mflux model:** add a family to `make_model()` in `mlx_worker.py` and an entry with `"kind": "mlx"`, its `mlxFamily` and `defaults` to `Core/catalog.json`. The repos at [huggingface.co/mflux-community](https://huggingface.co/mflux-community) are the pre-quantized weights.

On 16 GB, prefer 4-bit (`-q4`) weights and keep other apps light. Qwen-Image 2.1 Turbo at about 10 GB is the upper limit.

`Backends.make(for:)` in `Core/ImageBackend.swift` is where a backend is chosen.

## Layout
```
App/            SwiftUI app, views, debug smoke test
Core/           request/record types, catalog, model store + HF downloader,
                generator (one resident model), image saver, prompt enhancer,
                MLX runtime installer, backends/ (Core ML SD, MLX worker)
tools/convert/  checkpoint -> Core ML conversion script
```
