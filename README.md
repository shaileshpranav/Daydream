# CoreMLImageGen

A native SwiftUI Mac app that runs text-to-image models locally. It is tuned for an **M1 Pro with 16 GB** of RAM. It has two backends: **Core ML** for Stable Diffusion 1.5/2.1/XL (Neural Engine friendly), and **MLX** for newer quantized models such as Z-Image, FLUX.2 and Qwen-Image (see [MLX models](#mlx-models-z-image-flux2-qwen-image)).

- **Create** (was Generate): a description box with **Surprise Me** and one-click **Style** chips (Photo, Watercolor, Anime…, added to the prompt as visible text), a **Shape** picker, **Quality** (Quick / Standard / Extra Detail: 0.6×, 1× and 1.5× the model's recommended steps) and how many pictures to make. Negative prompt ("Things to avoid"), steps, guidance, seed ("variation number"), scheduler and LoRAs are under **Show advanced options**. With no model installed, Create shows a welcome screen with one button that downloads the recommended starter model. Every image is saved automatically; under it are Save…, Share, Copy and More (Edit This Picture, Reuse These Settings, Show in Finder).
- **Queue** ("Up Next"): ⌘↩ adds the current settings as a job; the button says **Add to Queue** while something is running. **Make N pictures** queues a batch with consecutive seeds (42, 43, 44…), so any one can be reproduced. The queue list under the image shows each job's progress and lets you reorder or remove waiting jobs, cancel the running one, cancel everything, clear finished jobs, and reuse a finished job's settings. Jobs run one at a time on the single resident model; consecutive jobs on the same model reuse it without reloading. Each job captures its settings when queued, so editing the prompt doesn't change jobs already waiting.
- **Image-to-image**: in the **Start Image** section, drop an image or choose one, or pick **Use as Start Image** from a gallery image's menu or a finished queue job. **How much to change it** (0.05–1, "A little" to "A lot") sets how much to redraw: low keeps the composition and details, high mostly follows the prompt. It works on every model. Core ML models scale and centre-crop the start image to their fixed size; MLX models switch to the aspect closest to the image. The start image is copied into `Application Support/CoreMLImageGen/StartImages`, so queued jobs and saved settings keep working if the original moves.
- **Prompt enhancer** (⌘E): turns a short idea into a detailed prompt and negative prompt using Apple Intelligence, on device. See [Prompt enhancer](#prompt-enhancer).
- **My Pictures** (was Gallery): every image in `~/Pictures/CoreMLImageGen`, searchable by description. Click one to open it full size:
  - Fit or actual size: double-click, pinch, or ⌘0, ⌘1, ⌘+ and ⌘−.
  - **←** and **→** move through the gallery, and **Esc** goes back.
  - A side panel shows how it was made: prompt, model, seed, steps, guidance, size, LoRAs, start image and time.
  - Actions: Use These Settings, Use as Start Image, Copy Image (⌘C), Copy Prompt, Show in Finder, and Move to Trash (⌘⌫).
- **Model manager**: models, LoRAs and installing new ones. See [Model manager](#model-manager).
- **Fast start:** the selected model loads in the background 1.5 s after you pick it, so Generate starts at once. Turn this off in Settings to keep memory free until you generate.
- **Seeds:** **New random seed each time** is on by default; the seed field shows the one used, so you can turn the toggle off and keep it to make variations.
- **While it runs:** the progress bar shows time remaining. **Esc** cancels the current image. The Dock icon shows how many images are left, and a notification arrives when a batch finishes while you're in another app. Click a finished job in the queue to view its image.
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
| SDXL base, 4.5-bit (GPU) | 20, DPM-Solver++ | ~7 min the first time | **154 s** (7.7 s/step) | With **Faster GPU maths** (16-bit accumulation, on by default): 13% faster than 32-bit (174 s, 8.7 s/step). Same seed: PSNR 35 dB; side by side the images match, with only fine wrinkle-texture differences at 100% zoom. Turn it off in Settings if you need exact 32-bit output |
| Z-Image Turbo, 4-bit (MLX) | 9 | ~11 s | **170 s** at 1024×1024 | About 18 s per step |
| FLUX.2 Klein 4B, 4-bit (MLX) | 4 | ~6 s (no compile step) | **82 s** at 1024×1024 | About 16 s per step plus text encoding and decode. Same seed gives identical pixels. Smaller aspect sizes are proportionally faster |

The download speed of the Hugging Face models depends on your connection; 1.6 GB took about 29 minutes here.

## Model manager
The **Models** sidebar item has three tabs: My Models, Style Add-ons (LoRAs) and Get Models.

**Models:** every installed model, with disk use and free space at the top. Select one to:
- rename it;
- see an estimate of how much memory it needs while generating on this Mac (comfortable, tight, or likely to swap);
- edit the default steps and guidance it starts with (and **Reset to Built-in**), its base size (MLX) or compute units (Core ML);
- **Load Now** or **Unload** it, or **Use in Generate**;
- **Move to Trash**, with a confirmation; it stays recoverable until the Trash is emptied.

**LoRAs:** everything in `Models/Loras`, with the base model each one is for, its size and training steps. For each, set a **default strength** and **trigger words**; suggestions come from its training captions when the file records them. In Generate, a LoRA then starts at that strength and offers **Insert trigger words**. You can import files, download a LoRA by Hugging Face repo, or move one to the Trash.

**Get Models:** the catalog comes first, with a plain description, download size and speed for each model; downloading an MLX model also starts the MLX runtime setup. The options below are under **Show advanced install options**.
- **From Hugging Face (MLX):** paste any mflux-format repo (e.g. `mflux-community/flux2-klein-9b-mflux-q4`). The family is detected from the name, and you can change it. Supported families: Z-Image Turbo, Z-Image (base), FLUX.2 Klein 4B and 9B, Qwen-Image 2.1 Turbo and base.
- **Catalog:** shows each model's download size and estimated memory.
- **Import** your own Core ML conversion, and install the MLX runtime.

Downloads resume from where they stopped after a dropped connection, instead of restarting multi-GB files.

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
- **Live preview:** about three previews per image (Settings → Live preview). Each shows the model's current guess at the finished image: x₀ = xₜ − σₜ·v, from the scheduler's step inputs. That's much clearer than the noisy in-between latents. Previews decode at half size, at 1.1–1.4 s each on FLUX.2 Klein (6% of the image time) and 0.3–0.6 s on Z-Image at 512 px (3%). With previews on, the final image is pixel-identical to the one without. Qwen-Image 2.1's preview path hasn't been run yet.
- **Batches reuse the prompt encoding:** Z-Image and FLUX.2 run a 4B text encoder for every image, about 2 s each on this M1 Pro. The worker keeps the last four encodings, so a batch with the same prompt encodes it once. Qwen-Image 2.1 already caches its own.
- **Image-to-image memory:** start images are encoded in 512 px tiles. Encoding a 1024 px image in one pass added ~5.7 GB (FLUX.2 Klein 4B peaked at 10.3 GB, against 6.9 GB tiled), which made a 16 GB Mac swap so hard that one image took 16 minutes. Tiled, it takes 43–69 s.

**Adding another mflux model:** for a supported family, use **Add Models → From Hugging Face**. To support a new family, add it to `make_model()` in `mlx_worker.py` and to `MLXFamilies.all` in `Core/MLXFamilies.swift` (with its defaults and repo-name detection); optionally add a catalog entry to `Core/catalog.json`. The repos at [huggingface.co/mflux-community](https://huggingface.co/mflux-community) are the pre-quantized weights.

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
