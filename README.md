# CoreMLImageGen

A native SwiftUI Mac app that runs text-to-image models locally. It is tuned for an **M1 Pro with 16 GB** of RAM. It has two backends: **Core ML** for Stable Diffusion 1.5/2.1/XL (Neural Engine friendly), and **MLX** for newer quantized models such as Z-Image, FLUX.2, Qwen-Image and MOSS-Image (see [MLX models](#mlx-models-z-image-flux2-qwen-image)).

- **Layout** (inspired by InvokeAI): a dark theme (or light, or matching macOS: Settings → General or View → Appearance) with an icon rail on the left for Create, My Pictures, Queue and Models (⌥⌘1–⌥⌘4) and Settings. There's no window toolbar: every section has the same header bar along its top. Create has three panels: settings on the left, the image in the middle and a gallery strip on the right (toggle it with the button at the right end of the image toolbar). The eye button next to it turns the live preview off and on; turning it off hides the preview at once, and the change reaches every picture that starts after it, including ones already queued.
- **Create**: the gold **Create** button, how many pictures (×N) and Stop (Esc) stay pinned at the top of the left panel. Below them are the **Prompt** (with things to avoid, **Surprise Me**, **Add Detail** and one-click **Style** chips that add visible text to the prompt), then collapsible **Generation** (model, Quality Quick / Standard / Extra Detail = 0.6×, 1× and 1.5× the recommended steps, steps, guidance, scheduler), **Image** (shape and seed), **Start Image** and **LoRAs** sections, each showing a summary when collapsed. Above the image is a toolbar: use prompt, use seed, use all settings, edit this picture, info (⌘I, how it was made), copy, save, share, show in Finder and trash; a thin bar under it shows progress. Zoom the image with the controls in its top-right corner, ⌘0 (fit), ⌘1 (actual size), ⌘+ and ⌘−, a pinch, or a double-click; scroll to move around. Click a gallery thumbnail to view it. With no model installed, Create shows a welcome screen with one button that downloads the recommended starter model. Every image is saved automatically.
- **Queue**: ⌘↩ adds the current settings as a job; the button says **Add to Queue** while something is running. **×N** queues a batch with consecutive seeds (42, 43, 44…), so any one can be reproduced. The **Queue** section (its rail icon shows how many are left) shows each job's progress and lets you reorder or remove waiting jobs, cancel the running one, cancel everything, clear finished jobs, and reuse a finished job's settings. Jobs run one at a time on the single resident model; consecutive jobs on the same model reuse it without reloading. Each job captures its settings when queued, so editing the prompt doesn't change jobs already waiting.
- **Image-to-image**: in the **Start Image** section, drop an image or choose one, or pick **Use as Start Image** from a gallery image's menu or a finished queue job. **How much to change it** (0.05–1, "A little" to "A lot") sets how much to redraw: low keeps the composition and details, high mostly follows the prompt. It works on every model except MOSS-Image, whose mflux port has no image-to-image (its Start Image section says so and offers to remove a leftover start image). Core ML models scale and centre-crop the start image to their fixed size; MLX models switch to the aspect closest to the image. The start image is copied into `Application Support/CoreMLImageGen/StartImages`, so queued jobs and saved settings keep working if the original moves.
- **Prompt enhancer** (⌘E): turns a short idea into a detailed prompt and negative prompt on device, with Apple Intelligence, a local MLX language model, or Ollama. See [Prompt enhancer](#prompt-enhancer).
- **My Pictures** (was Gallery): every image in `~/Pictures/CoreMLImageGen`, searchable by description. **Select** (or ⌘-click, or ⇧-click for a range) picks several pictures to copy, share, show in Finder or move to the Trash together; ⌘A selects all and Esc finishes. Right-clicking one of several selected pictures acts on all of them. Click one to open it full size:
  - Fit or actual size: double-click, pinch, or ⌘0, ⌘1, ⌘+ and ⌘−.
  - **←** and **→** move through the gallery, and **Esc** goes back.
  - A side panel shows how it was made: prompt, model, seed, steps, guidance, size, LoRAs, start image and time.
  - Actions: Use These Settings, Use as Start Image, Copy Image (⌘C), Copy Prompt, Show in Finder, and Move to Trash (⌘⌫).
- **Model manager**: models, LoRAs and installing new ones. See [Model manager](#model-manager).
- **Settings** (⌘, or the gear at the bottom of the rail) is a section of the main window with six tabs along its header:
  - **General**: appearance (Match System, Light or Dark), preloading, the Create screen's seed, gallery and info defaults, batch notifications, the Dock badge, and Reset All Settings.
  - **Speed & Memory**: Faster GPU maths, step reuse, live preview, the model in memory, freeing the picture model after 5–60 minutes unused (off by default), how long an Add Detail model stays loaded (3 minutes by default; Ollama is asked to keep its model for the same time), the Add Detail model in memory with an Unload button, and Free All Memory.
  - **Add Detail**: the prompt enhancer engine and its model, and an Unload button for the model in memory (see [Prompt enhancer](#prompt-enhancer)). While one is loaded, an eject button next to Add Detail in Create frees it too.
  - **Storage**: each folder the app keeps files in (pictures, start images, models, LoRAs, Add Detail models, MLX runtime) with its size and a Finder button, and the free disk space.
  - **MLX Runtime**: install, update or reinstall its packages, the worker log, the families it runs, and moving it to the Trash.
  - **About**: version, chip, memory, macOS and the keyboard shortcuts.
- **Fast start:** the selected model loads in the background 1.5 s after you pick it, so Generate starts at once. Turn this off in Settings → General to keep memory free until you generate.
- **Seeds:** **New random seed each time** is on by default; the seed field shows the one used, so you can turn the toggle off and keep it to make variations.
- **While it runs:** the progress bar shows time remaining. **Esc** cancels the current image. The Dock icon shows how many images are left, and a notification arrives when a batch finishes while you're in another app (both can be turned off in Settings → General). Click a finished job in the queue to view its image.
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

`-section Settings` (any section name) opens the app on that section. `-snapshots <folder>` saves a PNG of Create, My Pictures (in select mode, two pictures selected) and each Settings tab there and quits; add `-appearance light` or `-appearance dark` to pick the look. The app draws these itself, so they need no screen-recording permission:
```bash
open -n build/Build/Products/Debug/CoreMLImageGen.app --args -snapshots /tmp/shots -appearance light
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
| `mlx-moss-image-sft-q4` | MOSS-Image SFT, 4-bit (MLX) | 7.5 GB | GPU, weights' precision | ✅ needs MLX runtime; tight on 16 GB (11.7–12.9 GB peak), see [MOSS-Image](#moss-image) |
| `mlx-iris-3b-turbo-q4` | Iris-3B Turbo, 4-bit (MLX) | 5.1 GB | GPU, weights' precision | ⚠️ not yet run on this Mac, see [Newer mflux models](#newer-mflux-models) |
| `mlx-anima-turbo-q4` | Anima Turbo, 4-bit (MLX) | 3.1 GB | GPU, float16 | ⚠️ not yet run on this Mac; non-commercial license |
| `mlx-flux3-klein-q4` | FLUX 3 Klein, 4-bit (MLX) | 5.3 GB | GPU, float16 | ⚠️ not yet run on this Mac; FLUX Kommunity license |
| `mlx-ernie-image-turbo-q4` | ERNIE-Image Turbo, 4-bit (MLX) | 6.6 GB | GPU, weights' precision | ⚠️ not yet run on this Mac |

Models are stored in `~/Library/Application Support/CoreMLImageGen/Models/<id>/`, each with a `model.json`. The catalog lives in `Core/catalog.json`. Adding an SD or SDXL repo there needs no code changes.

The **first load** of a model compiles it for this Mac's Neural Engine or GPU, which can take a few minutes. Later loads are fast.

### Measured on this M1 Pro (16 GB)
| Model | Steps | First load (compiles for the Neural Engine, once) | Per image | Notes |
|---|---|---|---|---|
| SD 1.5, 6-bit palettized | 25, DPM-Solver++ | ~4.6 min | **16 s** | Same seed gives identical pixels. App footprint ~185 MB (Neural Engine memory is counted separately) |
| SDXL base, 4.5-bit (GPU) | 20, DPM-Solver++ | ~7 min the first time | **154 s** (7.7 s/step) | With **Faster GPU maths** (16-bit accumulation, on by default): 13% faster than 32-bit (174 s, 8.7 s/step). Same seed: PSNR 35 dB; side by side the images match, with only fine wrinkle-texture differences at 100% zoom. Turn it off in Settings if you need exact 32-bit output. Each picture records which one it used (**GPU maths** in the info panels) |
| Z-Image Turbo, 4-bit (MLX) | 9 | ~11 s | **170 s** at 1024×1024 | About 18 s per step |
| FLUX.2 Klein 4B, 4-bit (MLX) | 4 | ~6 s (no compile step) | **82 s** at 1024×1024 | About 16 s per step plus text encoding and decode. Same seed gives identical pixels. Smaller aspect sizes are proportionally faster |
| MOSS-Image SFT, 4-bit (MLX), Fast mode | 8, guidance 1 | ~10 s | **100 s** at 768×768 (105 s for the first) | Peak MLX memory 12.9 GB (the LoRA stays as separate layers). Clean text on the sign |
| MOSS-Image SFT, 4-bit (MLX) | 50, guidance 3, step reuse on | – | **869 s** (14.5 min) at 768×768 | Peak 11.7 GB. With step reuse off, same seed: PSNR 27.1 dB against it, and side by side the two look the same (same layout, same lettering; small differences in snow and branches). The step-reuse-off run's time (4,566 s) isn't usable: other heavy work was running at the same time and the Mac swapped (3.5 GB of swap in use afterwards) |

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
- **From Hugging Face (MLX):** paste any mflux-format repo (e.g. `mflux-community/flux2-klein-9b-mflux-q4`). The family is detected from the name, and you can change it. Supported families: Z-Image Turbo, Z-Image (base), FLUX.2 Klein 4B and 9B, Qwen-Image 2.1 Turbo and base, MOSS-Image SFT and base, FLUX 3 Klein, Iris-3B Turbo, Anima Turbo, Aesthetic and base, ERNIE-Image Turbo and base.
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
**Enhance** (⌘E, under the prompt) rewrites your idea on device. Nothing leaves the Mac. **Settings → Add Detail** picks the engine:

- **Apple Intelligence** (default): Apple's Foundation Models. Needs macOS 26+ with Apple Intelligence turned on.
- **MLX language model**: an instruct model run with `mlx-lm` in the MLX runtime's venv, in its own worker process. Works on any Apple silicon Mac. The model list has three groups:
  - **Recommended**: Qwen3 4B Instruct (2.3 GB, the default), Qwen3.5 2B, Llama 3.2 3B, Qwen3.5 4B, Gemma 3 4B and Qwen3.5 9B (6 GB, best rewrites, wants 24 GB+ of memory). Download from Settings into `~/Library/Application Support/CoreMLImageGen/PromptModels/`.
  - **Added from Hugging Face**: type any repo with MLX weights (e.g. `mlx-community/Phi-4-mini-instruct-4bit`) and press Add.
  - **Found on this Mac**: MLX-quantized chat models already in the Hugging Face cache (`~/.cache/huggingface/hub`, or `HF_HUB_CACHE`) are used in place, without downloading again. A catalog model already in the cache counts as downloaded.

  The model loads on the first Enhance and frees its memory after 3 minutes unused. Installs from before mlx-lm was added show **Update** on the MLX runtime row.
- **Ollama**: any model pulled into a running [Ollama](https://ollama.com) server (default `http://localhost:11434`; change the address to use another machine). Settings lists the server's models, smallest first. The app asks for JSON matching a schema, turns reasoning off, and uses a 2K context so a large server-wide `OLLAMA_CONTEXT_LENGTH` doesn't run a 16 GB Mac out of memory.

If the chosen engine isn't ready, the button is disabled and its help text says why.

- **Adapts to the model.** SD 1.x/2.x get a compact, comma-separated prompt, because their text encoder reads only about 75 tokens. SDXL gets natural sentences plus style terms. Both also get a matching negative prompt.
- **Keeps trigger words.** Quoted text and capitalized phrases from your idea (e.g. a LoRA trigger like `Monet Style`, or `Tokyo`) are guaranteed to survive verbatim. If the language model drops one, it's put back at the front.
- **Variations and Undo.** Press Enhance again for another variation; it always starts from what *you* wrote. **Undo** restores your original text. Editing the prompt yourself makes that edit the new starting point.
- About 3–5 s per enhance with Apple Intelligence on this M1 Pro. With MLX, loading the model adds a few seconds to the first enhance. If the model returns a fragment, the enhancer retries once automatically.

Debug check: `…/CoreMLImageGen -enhanceTest "portrait of a knight, Monet Style"` prints the result for SD 1.x, SDXL and MLX models. Add `-promptEnhancerEngine mlx -promptEnhancerModel <id>` or `-promptEnhancerEngine ollama -ollamaModel qwen3.5:9b` to test the other engines; it also lists the MLX models it found.

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
- **Live preview:** about three previews per image (Settings → Speed & Memory, or the eye button above the picture). Each shows the model's current guess at the finished image: x₀ = xₜ − σₜ·v, from the scheduler's step inputs. That's much clearer than the noisy in-between latents. Previews decode at half size, at 1.1–1.4 s each on FLUX.2 Klein (6% of the image time) and 0.3–0.6 s on Z-Image at 512 px (3%). With previews on, the final image is pixel-identical to the one without. Qwen-Image 2.1's preview path hasn't been run yet.
- **Batches reuse the prompt encoding:** Z-Image and FLUX.2 run a 4B text encoder for every image, about 2 s each on this M1 Pro. The worker keeps the last four encodings, so a batch with the same prompt encodes it once. Qwen-Image 2.1 and MOSS-Image cache their own; the worker trims those caches to the same four entries, because mflux never empties them in a long-lived worker.
- **Skip near-identical steps** (Settings → Speed & Memory, on by default): MOSS-Image and Qwen-Image 2.1 pass mflux's `step_cache_ratio` 0.25. On the quarter of steps that change least, mflux reuses the previous step's model output instead of running the transformer. The first and last 10% of steps always run, and runs under 10 steps skip nothing (so Qwen-Image 2.1 Turbo at 8 steps is unchanged). The image differs slightly from one made without it (MOSS-Image, same seed: PSNR 27.1 dB, the same picture side by side), so each picture's settings record the ratio used (shown as **Skipped steps** in the info panels). "Use These Settings" can't switch the setting back for you: to remake such a picture exactly, keep it on. Its time saving isn't measured yet: the comparison run was slowed by swapping.
- **LoRAs from repos with several files:** a Hugging Face repo with more than one `.safetensors` (e.g. a distillation LoRA that also ships a time embedding and a full transformer) is added as `repo:file`, picking the top-level file named like a LoRA. A bare repo name would make mflux refuse it, or download every file in the repo.
- **Image-to-image memory:** start images are encoded in 512 px tiles. Encoding a 1024 px image in one pass added ~5.7 GB (FLUX.2 Klein 4B peaked at 10.3 GB, against 6.9 GB tiled), which made a 16 GB Mac swap so hard that one image took 16 minutes. Tiled, it takes 43–69 s.

**Adding another mflux model:** for a supported family, use **Add Models → From Hugging Face**. To support a new family, add a row to `FAMILIES` in `mlx_worker.py` (module, class and `ModelConfig` accessor) and to `MLXFamilies.all` in `Core/MLXFamilies.swift` (with its defaults and repo-name detection); optionally add a catalog entry to `Core/catalog.json`. The repos at [huggingface.co/mflux-community](https://huggingface.co/mflux-community) are the pre-quantized weights.

On 16 GB, prefer 4-bit (`-q4`) weights and keep other apps light. Qwen-Image 2.1 Turbo at about 10 GB is the upper limit.

### MOSS-Image
[MOSS-Image](https://github.com/OpenMOSS/MOSS-Image) (OpenMOSS, Apache 2.0) is a 4.9B diffusion transformer with a Qwen3.5-9B text encoder and the FLUX.2 VAE. It's good at legible text (English and Chinese), long prompts and JSON layouts. mflux 0.24 (the pinned version) has an MLX port, so it runs in the same worker as the other MLX models; no PyTorch install is needed. The catalog offers `mflux-community/moss-image-sft-mflux-q4` (7.5 GB). Other quantizations and the base model install from **From Hugging Face** (`mflux-community/moss-image-sft-mflux-q3`…`-q8`, family detected as MOSS-Image SFT or base).

- **Defaults:** 50 steps, guidance 3, an empty negative prompt, at 768 px base size. Each step runs the transformer twice (CFG; the negative pass skips layer 22, as the model card recommends). On this M1 Pro that's 869 s per picture at 768 px even with step reuse on, and 11.7 GB peak memory, so the model manager rates it "Tight". Use Fast mode.
- **Fast mode** (Generation section, MOSS-Image SFT only): one switch that adds the community 8-step LoRA `lodestones/MOSS-Image-SFT-8-steps-dmd` and sets 8 steps and guidance 1. That's 8 transformer runs instead of 100. The first time, it downloads the LoRA (1.2 GB, with progress) into `Models/Loras/lodestones__MOSS-Image-SFT-8-steps-dmd/`; it's listed in the LoRAs section like any other. Quality and **Use Recommended** count from 8 steps while it's on; turning it off goes back to 50 steps and guidance 3. It's a LoRA in the request, so saved pictures and queued jobs keep it. Switching to another model removes it (it was trained on SFT, not base). Step reuse is skipped in Fast mode, because every distilled step counts. LoRAs on MOSS-Image stay separate layers (mflux's default), which needs about 1.2 GB more memory. `darask0/MOSS-Image_4-step_adapter_lora` works the same way at 4 steps if you add it yourself.
- **No start image:** mflux's port has no image-to-image.
- **Precision:** mflux has no float16 compute option for MOSS-Image, and its activations are known to overflow float16, so it runs at the precision of its weights rather than the float16 the other MLX models use on M1.
- **Live preview** works the same way as FLUX.2 (it uses the FLUX.2 VAE).

### Newer mflux models
mflux 0.24 also ships these, and they fit a 16 GB Mac at 4-bit. Settings come from each family's mflux README:

| Family | 4-bit download | Defaults | Start image | LoRAs | float16 | License |
|---|---|---|---|---|---|---|
| FLUX 3 Klein (Black Forest Labs) | 5.3 GB | 16 steps, 768 px | no | yes | yes | FLUX Kommunity (mostly non-commercial) |
| Iris-3B Turbo (Speridlabs) | 5.1 GB | 4 steps, 1024 px | no | no | no | Apache 2.0 |
| Anima Turbo / Aesthetic / base (2B, anime) | 3.1 GB | 10 steps / 30 steps, guidance 4 | no | yes | yes | non-commercial |
| ERNIE-Image Turbo / base (Baidu, 8B) | 6.6 GB | 8 steps / 50 steps, guidance 4 | yes | yes | no | Apache 2.0 |

- **Distilled variants** (FLUX 3 Klein, Iris, Anima Turbo, ERNIE Turbo) ignore guidance and the negative prompt, so that field hides. mflux rejects any guidance but 1 on ERNIE-Image Turbo.
- **FLUX 3 Klein starts at 768 px.** mflux's published 1024 px peak (18.5 GB at 4-bit) predates its lower-memory VAE decode, and no newer figure was given. Raise the base size in the model manager if it runs comfortably.
- **No live preview** for these four yet: their latent layouts and decoders aren't mapped in the worker (Iris has no VAE at all).
- **Iris-3B takes no LoRAs** in mflux, so its LoRA section hides and switching to it clears LoRAs.
- **Left out:** FLUX 3 Klein base and Iris-3B base (undistilled research checkpoints, 50 and 100 steps with CFG). FIBO 2 is left out because it is trained on JSON captions and mflux measured about 220 s per image on an M5 Max. Krea 2 (15.8 GB at 4-bit), Ideogram 4 (11.6 GB at 3-bit) and Ming-Image (16.5 GB at 5-bit) are too big for 16 GB. Boogu (10B) and Lens (20B text encoder) are too.
- **How the worker loads them:** `FAMILIES` in `mlx_worker.py` maps each family to its mflux class and config. Options (LoRAs, float16, negative prompt, start image, step reuse) are passed only when that class's signature takes them, so a new family needs only a table row and an `MLXFamilies.all` entry.

**Not yet verified here:** none of these four families has made a picture on this Mac. The worker's table was checked against the installed mflux: every family resolves to its class and config, and the options are filtered as expected.

**Verified here (MOSS-Image):** `-mossTest YES -full YES` (Debug builds) installs the 4-bit model and the Fast mode LoRA if needed, then makes two Fast mode pictures and two 50-step pictures (step reuse on and off), printing time and peak MLX memory; results are in the timing table above. Not yet verified: live preview with real weights (the test runs with previews off), and how much step reuse saves, since its comparison run was slowed by swapping.

`Backends.make(for:)` in `Core/ImageBackend.swift` is where a backend is chosen.

## Layout
```
App/            SwiftUI app, views, debug smoke test
Core/           request/record types, catalog, model store + HF downloader,
                generator (one resident model), image saver, prompt enhancer,
                MLX runtime installer, backends/ (Core ML SD, MLX worker)
tools/convert/  checkpoint -> Core ML conversion script
```
