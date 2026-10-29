"""Long-lived MLX (mflux) worker for CoreMLImageGen.

The app starts this with the venv's Python and talks to it in JSON lines:
requests on stdin, events on stdout. Everything mflux and its libraries print
goes to stderr instead, so stdout carries only protocol lines.

  -> {"op": "load", "family": "z-image-turbo", "path": "/…/model", "loras": [{"path": "…", "scale": 0.8}], "float16": true,
      "untiled_decode": false}   (optional, Debug builds: decode in one pass, for comparison)
  <- {"event": "loaded", "seconds": 12.3}
  -> {"op": "generate", "prompt": "…", "negative_prompt": "", "seed": 42, "steps": 9,
      "guidance": 0.0, "width": 1024, "height": 1024, "out": "/tmp/x.png",
      "step_cache_ratio": 0.25}   (optional; MOSS-Image and Qwen-Image 2.1 only)
  <- {"event": "step", "step": 1, "total": 9} …
  <- {"event": "done", "path": "/tmp/x.png", "seconds": 61.0}
  <- {"event": "error", "message": "…"} / {"event": "cancelled"}

The prompt rewriter runs its own instance with a small language model (mlx-lm):

  -> {"op": "load_lm", "path": "/…/prompt-model"}
  <- {"event": "loaded", "seconds": 2.1}
  -> {"op": "chat", "messages": [{"role": "system", "content": "…"}, …],
      "temperature": 0.7, "max_tokens": 300}
  <- {"event": "reply", "text": "…", "seconds": 3.4}

While a picture is being made, the app can change how often it previews; this takes
effect at the next step (stdin is read on its own thread for it):

  -> {"op": "preview", "every": 3}   (0 turns previews off)

SIGUSR1 cancels the running generation at the next denoising step. To free
memory the app simply terminates the process.
"""
import gc
import json
import os
import queue
import signal
import sys
import threading
import time
import traceback

# Keep a private handle on the real stdout for protocol lines; route all other
# printing (mflux logs, tqdm, warnings) to stderr.
_protocol = os.fdopen(os.dup(sys.stdout.fileno()), "w", buffering=1)
sys.stdout = sys.stderr

_cancel = False


def _on_cancel(signum, frame):
    global _cancel
    _cancel = True


signal.signal(signal.SIGUSR1, _on_cancel)


def emit(event, **fields):
    _protocol.write(json.dumps({"event": event, **fields}) + "\n")
    _protocol.flush()


# Family -> (module, class, ModelConfig accessor). Keep in sync with MLXFamilies.all in
# Core/MLXFamilies.swift.
FAMILIES = {
    "z-image-turbo": ("mflux.models.z_image", "ZImageTurbo", "z_image_turbo"),
    "z-image": ("mflux.models.z_image", "ZImage", "z_image"),
    "flux2-klein-4b": ("mflux.models.flux2", "Flux2Klein", "flux2_klein_4b"),
    "flux2-klein-9b": ("mflux.models.flux2", "Flux2Klein", "flux2_klein_9b"),
    "flux3-klein": ("mflux.models.flux3", "Flux3Klein", "flux3_image_klein"),
    "qwen-image-2.1-turbo": ("mflux.models.qwen21.variants.txt2img.qwen_image_21", "QwenImage21", "qwen_image_21_turbo"),
    "qwen-image-2.1": ("mflux.models.qwen21.variants.txt2img.qwen_image_21", "QwenImage21", "qwen_image_21"),
    "moss-image": ("mflux.models.moss_image", "MOSSImage", "moss_image_sft"),
    "moss-image-base": ("mflux.models.moss_image", "MOSSImage", "moss_image_base"),
    "iris-3b-turbo": ("mflux.models.iris", "Iris", "iris_3b"),
    "anima-turbo": ("mflux.models.anima", "Anima", "anima_turbo"),
    "anima-aesthetic": ("mflux.models.anima", "Anima", "anima_aesthetic"),
    "anima-base": ("mflux.models.anima", "Anima", "anima_base"),
    "ernie-image-turbo": ("mflux.models.ernie_image", "ErnieImage", "ernie_image_turbo"),
    "ernie-image": ("mflux.models.ernie_image", "ErnieImage", "ernie_image"),
}


def _accepts(function, name):
    import inspect
    return name in inspect.signature(function).parameters


def make_model(family, path, loras, float16):
    import importlib
    import mlx.core as mx
    from mflux.models.common.config import ModelConfig

    if family not in FAMILIES:
        raise ValueError(f"Unknown model family: {family}")
    module, class_name, config = FAMILIES[family]
    cls = getattr(importlib.import_module(module), class_name)
    kwargs = dict(model_path=path, model_config=getattr(ModelConfig, config)())
    # The model classes differ in what they take (Iris has no LoRAs; MOSS-Image, Iris and
    # ERNIE-Image have no compute_precision), so pass only what each accepts.
    if loras:
        if not _accepts(cls.__init__, "lora_paths"):
            raise ValueError(f"{class_name} doesn't take LoRAs. Remove them to use this model.")
        kwargs["lora_paths"] = [l["path"] for l in loras]
        kwargs["lora_scales"] = [float(l["scale"]) for l in loras]
    # M1 GPUs have no native bfloat16; float16 compute is ~25% faster there. Families without
    # the option run at the precision of their weights (MOSS-Image also overflows float16).
    if float16 and _accepts(cls.__init__, "compute_precision"):
        kwargs["compute_precision"] = mx.float16
    return cls(**kwargs)


# --- Live preview -----------------------------------------------------------------------
#
# The per-step callback only sees the noisy latents, which look like static early on. These
# models are rectified-flow (x_t = (1 - s) x0 + s * noise, the network predicts v), and both
# mflux schedulers step as x_next = x_t + v * (s_next - s_t). So remembering each step's
# inputs gives the model's current guess at the finished image: x0 = x_t - s_t * v.

_step_inputs = {}


def _record_scheduler_steps():
    from mflux.models.common.schedulers.flow_match_euler_discrete_scheduler import FlowMatchEulerDiscreteScheduler
    from mflux.models.common.schedulers.linear_scheduler import LinearScheduler
    from mflux.models.moss_image.model.moss_image_scheduler.moss_image_scheduler import MOSSImageScheduler

    for cls in (FlowMatchEulerDiscreteScheduler, LinearScheduler, MOSSImageScheduler):
        if getattr(cls.step, "_records_inputs", False):
            continue
        original = cls.step

        def step(self, noise, timestep, latents, _original=original, **kwargs):
            sigmas = kwargs.get("sigmas", self.sigmas)
            _step_inputs["value"] = (latents, noise, sigmas[timestep])
            return _original(self, noise, timestep, latents, **kwargs)

        step._records_inputs = True
        cls.step = step


def _latent_creator(family):
    if family.startswith("z-image"):
        from mflux.models.z_image.latent_creator.z_image_latent_creator import ZImageLatentCreator
        return ZImageLatentCreator
    if family.startswith("flux2-klein"):
        from mflux.models.flux2.latent_creator.flux2_latent_creator import Flux2LatentCreator
        return Flux2LatentCreator
    if family.startswith("moss-image"):
        # Already the packed 128-channel FLUX.2 VAE layout, decoded like FLUX.2's below.
        from mflux.models.moss_image.latent_creator.moss_image_latent_creator import MOSSImageLatentCreator
        return MOSSImageLatentCreator
    if family.startswith("qwen-image-2.1"):
        from mflux.models.qwen21.latent_creator.qwen21_latent_creator import Qwen21LatentCreator
        return Qwen21LatentCreator
    # FLUX 3, Iris (no VAE: it denoises pixels), Anima and ERNIE-Image: their latent layouts
    # and decoders haven't been mapped here, so they show no live preview.
    return None


def _half_size(latents):
    """2x2 average-pool a [B, C, (F,) H, W] latent, so the VAE decodes a quarter of the
    pixels. Full-size decodes cost ~7 s per preview on an M1 Pro (38% of a FLUX.2 image)."""
    import mlx.core as mx

    frame = latents.ndim == 5
    if frame:
        latents = latents[:, :, 0]
    b, c, h, w = latents.shape
    h2, w2 = h // 2 * 2, w // 2 * 2
    pooled = latents[:, :, :h2, :w2].reshape(b, c, h2 // 2, 2, w2 // 2, 2).mean(axis=(3, 5))
    return mx.expand_dims(pooled, 2) if frame else pooled


def save_preview(model, family, latents, config, seed, prompt, path):
    """Decodes the predicted finished image at half size (same unpack/decode path as
    mflux's own StepwiseHandler) and saves a small PNG."""
    from mflux.models.common.vae.vae_util import VAEUtil
    from mflux.utils.image_util import ImageUtil

    inputs = _step_inputs.get("value")
    if inputs is not None:
        before, velocity, sigma = inputs
        x0 = before - velocity.astype(before.dtype) * sigma.astype(before.dtype)
    else:
        x0 = latents
    unpacked = _latent_creator(family).unpack_latents(latents=x0, height=config.height, width=config.width)
    vae = model.vae
    if hasattr(vae, "unpack_packed_latents") and unpacked.shape[1] > getattr(vae, "latent_channels", 32):
        # FLUX.2: de-normalize and unpatchify to the plain 32-channel latent first.
        decoded = VAEUtil.decode(vae=vae, latent=_half_size(vae.unpack_packed_latents(unpacked)))
    else:
        decoded = vae.decode(_half_size(unpacked))
    image = ImageUtil.to_image(
        decoded_latents=decoded, config=config, seed=seed, prompt=prompt,
        quantization=model.bits, lora_paths=None, lora_scales=None, generation_time=0,
    ).image
    image.thumbnail((640, 640))
    image.save(path)


_preview = {"every": 0, "dir": None, "family": None, "model": None, "count": 0}


class Progress:
    def call_in_loop(self, t, seed, prompt, latents, config, time_steps):
        from mflux.utils.exceptions import StopImageGenerationException

        step, total = t + 1, config.num_inference_steps
        emit("step", step=step, total=total)
        if _cancel:
            raise StopImageGenerationException("cancelled")
        every = _preview["every"] if _latent_creator(_preview["family"]) is not None else 0
        # No preview on the last step: the finished image follows straight away.
        if every and step % every == 0 and step < total:
            import mlx.core as mx

            mx.eval(latents)  # finish this step's own work first, so `seconds` is the preview alone
            start = time.time()
            _preview["count"] += 1
            path = os.path.join(_preview["dir"], f"preview-{os.getpid()}-{_preview['count']}.png")
            try:
                save_preview(_preview["model"], _preview["family"], latents, config, seed, prompt, path)
                emit("preview", path=path, step=step, seconds=time.time() - start)
            except Exception:  # a preview must never break the generation
                traceback.print_exc()


# --- Prompt encoding reuse ------------------------------------------------------------------
#
# Z-Image and FLUX.2 run their text encoder (a 4B LLM) for every image, even when a batch
# repeats the same prompt. Qwen-Image 2.1 and MOSS-Image already keep their own
# prompt_cache, but it never forgets: trim_prompt_cache bounds it like ours.

PROMPT_CACHE_SIZE = 4


def trim_prompt_cache(model):
    cache = getattr(model, "prompt_cache", None)
    if isinstance(cache, dict):
        while len(cache) > PROMPT_CACHE_SIZE:
            cache.pop(next(iter(cache)))  # dicts keep insertion order: oldest first


def cache_prompt_encoding(model, family):
    import mlx.core as mx
    from collections import OrderedDict

    if family.startswith("z-image"):
        name = "_encode_prompts"
    elif family.startswith("flux2-klein"):
        name = "_encode_prompt_pair"
    else:
        return
    original = getattr(model, name)
    cache = OrderedDict()

    def cached(**kwargs):
        key = json.dumps(kwargs, sort_keys=True, default=str)
        if key in cache:
            cache.move_to_end(key)
            emit("encoded", cached=True, seconds=0.0)
            return cache[key]
        start = time.time()
        result = original(**kwargs)
        mx.eval([part for part in result if part is not None])  # store results, not lazy graphs
        cache[key] = result
        if len(cache) > PROMPT_CACHE_SIZE:
            cache.popitem(last=False)
        emit("encoded", cached=False, seconds=time.time() - start)
        return result

    setattr(model, name, cached)


def generate(model, family, req):
    kwargs = dict(
        seed=int(req["seed"]),
        prompt=req["prompt"],
        num_inference_steps=int(req["steps"]),
        width=int(req["width"]),
        height=int(req["height"]),
        guidance=float(req["guidance"]),
    )
    # Each option is passed only if this family's generate_image takes it: FLUX.2/3 Klein
    # and Iris have no negative prompt, only some families have image-to-image or step reuse.
    accepts = lambda name: _accepts(model.generate_image, name)
    # Image-to-image: image_strength is the share of steps skipped (higher keeps more).
    if req.get("image_path"):
        if not accepts("image_path"):
            raise ValueError("This model can't start from a picture. Remove the start image.")
        kwargs["image_path"] = req["image_path"]
        kwargs["image_strength"] = float(req["image_strength"])
    # Reuse the model output on the most similar steps instead of running the transformer.
    if req.get("step_cache_ratio") and accepts("step_cache_ratio"):
        kwargs["step_cache_ratio"] = float(req["step_cache_ratio"])
    if req.get("negative_prompt") and accepts("negative_prompt"):
        kwargs["negative_prompt"] = req["negative_prompt"]
    return model.generate_image(**kwargs)


def chat(lm, req):
    from mlx_lm import generate
    from mlx_lm.sample_utils import make_sampler

    model, tokenizer = lm
    # enable_thinking=False turns off Qwen3/3.5 reasoning; other chat templates ignore it.
    prompt = tokenizer.apply_chat_template(req["messages"], add_generation_prompt=True,
                                           enable_thinking=False)
    sampler = make_sampler(temp=float(req.get("temperature", 0.7)), top_p=0.9)
    text = generate(model, tokenizer, prompt=prompt, max_tokens=int(req.get("max_tokens", 300)),
                    sampler=sampler)
    # Some models still emit an (empty) reasoning block.
    if "</think>" in text:
        text = text.split("</think>", 1)[1]
    return text.strip()


def read_requests(requests):
    """Reads stdin on its own thread, so a preview change reaches a generation in progress.
    Everything else waits its turn on `requests`; None marks the end of input."""
    for line in sys.stdin:
        if not line.strip():
            continue
        req = json.loads(line)
        if req.get("op") == "preview":
            _preview["every"] = int(req.get("every", 0))
        else:
            requests.put(req)
    requests.put(None)


def main():
    global _cancel
    import mlx.core as mx
    from mflux.utils.exceptions import StopImageGenerationException

    model, family = None, None
    lm = None
    requests = queue.Queue()
    threading.Thread(target=read_requests, args=(requests,), daemon=True).start()
    emit("ready", pid=os.getpid())
    while (req := requests.get()) is not None:
        start = time.time()
        try:
            if req["op"] == "load":
                model = None
                gc.collect()
                mx.clear_cache()
                family = req["family"]
                model = make_model(family, req["path"], req.get("loras", []), req.get("float16", True))
                # Encode image-to-image start images in 512 px tiles. Encoding a 1024 px image
                # in one pass adds ~5.7 GB (measured on FLUX.2 Klein 4B: 10.3 GB peak vs 6.9 GB
                # tiled), enough to push a 16 GB Mac into heavy swapping.
                # Decode in tiles too where mflux says tiling costs nothing visually (every
                # decoder but FLUX.2's). The Qwen-Image VAE decoding 1024 px in one pass took
                # Anima Turbo to an 18.7 GB peak here; mflux's low-RAM mode tiles it the same way.
                from mflux.models.common.vae.tiling_config import TilingConfig
                if TilingConfig.may_tile_implicitly(model) and not req.get("untiled_decode"):
                    model.tiling_config = TilingConfig()
                else:
                    model.tiling_config = TilingConfig(vae_decode_tiles_per_dim=None)
                # Registered once per loaded model; mflux has no unregister.
                model.callbacks.register(Progress())
                cache_prompt_encoding(model, family)
                _record_scheduler_steps()
                emit("loaded", seconds=time.time() - start)
            elif req["op"] == "generate":
                if model is None:
                    raise RuntimeError("No model loaded")
                _cancel = False
                _step_inputs.clear()
                mx.reset_peak_memory()
                _preview.update(every=int(req.get("preview_every", 0)), family=family, model=model,
                                dir=os.path.dirname(req["out"]))
                image = generate(model, family, req)
                image.image.save(req["out"])
                trim_prompt_cache(model)
                peak_gb = mx.get_peak_memory() / 1e9  # weights plus this image's activations
                gc.collect()
                mx.clear_cache()
                emit("done", path=req["out"], seconds=time.time() - start, peak_gb=peak_gb)
            elif req["op"] == "load_lm":
                from mlx_lm import load
                lm = None
                gc.collect()
                mx.clear_cache()
                lm = load(req["path"])
                emit("loaded", seconds=time.time() - start)
            elif req["op"] == "chat":
                if lm is None:
                    raise RuntimeError("No language model loaded")
                text = chat(lm, req)
                emit("reply", text=text, seconds=time.time() - start)
            else:
                raise ValueError(f"Unknown op: {req['op']}")
        except StopImageGenerationException:
            emit("cancelled")
        except Exception as e:  # report and keep serving
            traceback.print_exc()
            emit("error", message=f"{type(e).__name__}: {e}")


if __name__ == "__main__":
    main()
