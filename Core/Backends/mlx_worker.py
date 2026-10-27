"""Long-lived MLX (mflux) worker for CoreMLImageGen.

The app starts this with the venv's Python and talks to it in JSON lines:
requests on stdin, events on stdout. Everything mflux and its libraries print
goes to stderr instead, so stdout carries only protocol lines.

  -> {"op": "load", "family": "z-image-turbo", "path": "/…/model", "loras": [{"path": "…", "scale": 0.8}], "float16": true}
  <- {"event": "loaded", "seconds": 12.3}
  -> {"op": "generate", "prompt": "…", "negative_prompt": "", "seed": 42, "steps": 9,
      "guidance": 0.0, "width": 1024, "height": 1024, "out": "/tmp/x.png"}
  <- {"event": "step", "step": 1, "total": 9} …
  <- {"event": "done", "path": "/tmp/x.png", "seconds": 61.0}
  <- {"event": "error", "message": "…"} / {"event": "cancelled"}

SIGUSR1 cancels the running generation at the next denoising step. To free
memory the app simply terminates the process.
"""
import gc
import json
import os
import signal
import sys
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


def make_model(family, path, loras, float16):
    import mlx.core as mx
    from mflux.models.common.config import ModelConfig

    kwargs = dict(
        model_path=path,
        lora_paths=[l["path"] for l in loras] or None,
        lora_scales=[float(l["scale"]) for l in loras] or None,
        # M1 GPUs have no native bfloat16; float16 compute is ~25% faster there.
        compute_precision=mx.float16 if float16 else None,
    )
    if family == "z-image-turbo":
        from mflux.models.z_image import ZImageTurbo
        return ZImageTurbo(model_config=ModelConfig.z_image_turbo(), **kwargs)
    if family == "flux2-klein-4b":
        from mflux.models.flux2 import Flux2Klein
        return Flux2Klein(model_config=ModelConfig.flux2_klein_4b(), **kwargs)
    if family == "qwen-image-2.1-turbo":
        from mflux.models.qwen21.variants.txt2img.qwen_image_21 import QwenImage21
        return QwenImage21(model_config=ModelConfig.qwen_image_21_turbo(), **kwargs)
    raise ValueError(f"Unknown model family: {family}")


class Progress:
    def __init__(self):
        self.total = 0

    def call_in_loop(self, t, seed, prompt, latents, config, time_steps):
        from mflux.utils.exceptions import StopImageGenerationException

        emit("step", step=t + 1, total=config.num_inference_steps)
        if _cancel:
            raise StopImageGenerationException("cancelled")


def generate(model, family, req):
    kwargs = dict(
        seed=int(req["seed"]),
        prompt=req["prompt"],
        num_inference_steps=int(req["steps"]),
        width=int(req["width"]),
        height=int(req["height"]),
        guidance=float(req["guidance"]),
    )
    # FLUX.2 Klein is guidance-distilled and takes no negative prompt.
    if family != "flux2-klein-4b" and req.get("negative_prompt"):
        kwargs["negative_prompt"] = req["negative_prompt"]
    return model.generate_image(**kwargs)


def main():
    global _cancel
    import mlx.core as mx
    from mflux.utils.exceptions import StopImageGenerationException

    model, family = None, None
    emit("ready", pid=os.getpid())
    for line in sys.stdin:
        if not line.strip():
            continue
        req = json.loads(line)
        start = time.time()
        try:
            if req["op"] == "load":
                model = None
                gc.collect()
                mx.clear_cache()
                family = req["family"]
                model = make_model(family, req["path"], req.get("loras", []), req.get("float16", True))
                # Registered once per loaded model; mflux has no unregister.
                model.callbacks.register(Progress())
                emit("loaded", seconds=time.time() - start)
            elif req["op"] == "generate":
                if model is None:
                    raise RuntimeError("No model loaded")
                _cancel = False
                image = generate(model, family, req)
                image.image.save(req["out"])
                gc.collect()
                mx.clear_cache()
                emit("done", path=req["out"], seconds=time.time() - start)
            else:
                raise ValueError(f"Unknown op: {req['op']}")
        except StopImageGenerationException:
            emit("cancelled")
        except Exception as e:  # report and keep serving
            traceback.print_exc()
            emit("error", message=f"{type(e).__name__}: {e}")


if __name__ == "__main__":
    main()
