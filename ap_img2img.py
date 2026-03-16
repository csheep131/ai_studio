import os
import time

import gradio as gr
import torch
from pathlib import Path
from diffusers import (
    StableDiffusionXLImg2ImgPipeline,
    EulerAncestralDiscreteScheduler,
    DPMSolverSDEScheduler,
    DPMSolverMultistepScheduler,
    DDIMScheduler,
)
from PIL import Image

MODEL_ID = os.environ.get("MODEL_ID", "stabilityai/stable-diffusion-xl-base-1.0")
BIND = os.environ.get("HOST", "127.0.0.1")
PORT = int(os.environ.get("PORT", "7860"))
LORA_DIR = Path("/opt/models/loras")
DEVICE = "cuda" if torch.cuda.is_available() else "cpu"
DTYPE = torch.float16 if DEVICE == "cuda" else torch.float32
pipe = None
INCOMPATIBLE_LORAS = {}

UNSUPPORTED_LORA_MARKERS = {
    ".lora_mid.": "unsupported LyCORIS/LoCon weights",
    ".hada_": "unsupported LoHa weights",
    ".lokr_": "unsupported LoKr weights",
}


def scan_loras():
    try:
        if not LORA_DIR.is_dir():
            return []
        return sorted(
            [p for p in LORA_DIR.rglob("*.safetensors") if p.is_file()],
            key=lambda p: (p.name.lower(), str(p)),
        )
    except Exception:
        return []


def inspect_lora(path: Path):
    try:
        from safetensors import safe_open
        with safe_open(str(path), framework="pt", device="cpu") as handle:
            keys = list(handle.keys())
        if not keys:
            return False, "file contains no tensor weights"
        for marker, reason in UNSUPPORTED_LORA_MARKERS.items():
            if any(marker in key for key in keys):
                return False, reason

        # Only block Flux LoRAs (top-level transformer keys, not transformer_blocks inside UNet)
        if any(k.startswith("transformer.") or k.startswith("lora_transformer.") for k in keys):
            print(f"[lora][BLOCKED] {path.name}: Flux LoRA (incompatible with SDXL)", flush=True)
            return False, "Flux LoRA — incompatible with SDXL pipeline"

        return True, ""
    except ImportError:
        return True, ""
    except Exception as exc:
        return False, f"failed to inspect file: {exc}"


def split_loras(paths):
    compatible = {}
    incompatible = {}
    seen_labels = set()
    for path in paths:
        label = path.name
        if label in seen_labels:
            label = str(path.relative_to(LORA_DIR))
        seen_labels.add(label)
        is_compatible, reason = inspect_lora(path)
        if is_compatible:
            compatible[label] = str(path)
        else:
            incompatible[label] = reason
    return compatible, incompatible


LORA_PATHS = scan_loras()
COMPATIBLE_LORAS, INCOMPATIBLE_LORAS = split_loras(LORA_PATHS)
HAS_LORAS = bool(COMPATIBLE_LORAS)

LORA_LABEL_TO_PATH = {"None": None, **COMPATIBLE_LORAS}
COMPATIBLE_LABELS = list(COMPATIBLE_LORAS.keys())
LORA_LABELS = list(LORA_LABEL_TO_PATH.keys())

SAMPLER_OPTIONS = ["Euler a", "DPM++ SDE", "DPM++ 2M Karras", "DDIM"]

SAMPLER_MAP = {
    "Euler a": lambda cfg: EulerAncestralDiscreteScheduler.from_config(cfg),
    "DPM++ SDE": lambda cfg: DPMSolverSDEScheduler.from_config(cfg),
    "DPM++ 2M Karras": lambda cfg: DPMSolverMultistepScheduler.from_config(cfg, use_karras_sigmas=True),
    "DDIM": lambda cfg: DDIMScheduler.from_config(cfg),
}

DEFAULT_NEG = (
    "anime, cartoon, graphic, text, painting, crayon, graphite, abstract, "
    "glitch, deformed, mutated, plastic, surreal, overexposed, "
    "blurry, distorted, low quality"
)


def load_pipeline():
    global pipe
    if pipe is not None:
        return pipe
    kwargs = {"torch_dtype": DTYPE, "use_safetensors": True}
    if DTYPE == torch.float16:
        kwargs["variant"] = "fp16"
    pipe = StableDiffusionXLImg2ImgPipeline.from_pretrained(MODEL_ID, **kwargs).to(DEVICE)
    if DEVICE == "cuda":
        pipe.enable_attention_slicing()
    return pipe


def prepare_image(init_image: Image.Image) -> Image.Image:
    image = init_image.convert("RGB")
    width = max(64, (image.width // 8) * 8)
    height = max(64, (image.height // 8) * 8)
    if width != image.width or height != image.height:
        image = image.resize((width, height))
    return image


def apply_loras(selected_labels, selected_weights):
    pipeline = load_pipeline()
    try:
        pipeline.unload_lora_weights()
    except Exception:
        pass

    adapter_names = []
    adapter_weights = []
    seen_labels = set()

    for idx, (label, weight) in enumerate(zip(selected_labels, selected_weights), start=1):
        if not label or label == "None":
            continue
        if label in seen_labels:
            continue
        seen_labels.add(label)
        lora_path = LORA_LABEL_TO_PATH.get(label)
        if not lora_path:
            continue
        adapter_name = f"lora{idx}"
        print(f"Lade LoRA: {label}", flush=True)
        try:
            pipeline.load_lora_weights(lora_path, adapter_name=adapter_name)
        except Exception as exc:
            raise RuntimeError(
                f"LoRA '{label}' konnte nicht geladen werden. "
                f"Details: {exc}"
            ) from exc
        adapter_names.append(adapter_name)
        adapter_weights.append(float(weight))

    if adapter_names:
        pipeline.set_adapters(adapter_names, adapter_weights=adapter_weights)


def set_scheduler(pipeline, sampler_name: str):
    factory = SAMPLER_MAP.get(sampler_name)
    if factory is not None:
        pipeline.scheduler = factory(pipeline.scheduler.config)
        print(f"[scheduler] {sampler_name}", flush=True)


def generate(prompt, negative_prompt, init_image, strength, guidance_scale, steps, seed, sampler, *lora_args):
    if init_image is None:
        raise gr.Error("Bitte ein Referenzbild hochladen.")

    pipeline = load_pipeline()
    set_scheduler(pipeline, sampler)

    selected_labels = []
    selected_weights = []
    for idx in range(0, len(lora_args), 2):
        label = lora_args[idx]
        weight = lora_args[idx + 1] if idx + 1 < len(lora_args) else 0.75
        selected_labels.append(label)
        selected_weights.append(weight)

    try:
        apply_loras(selected_labels, selected_weights)
    except Exception as exc:
        return None, f"LoRA error – {exc}"

    image = prepare_image(init_image)
    generator = None
    if seed is not None and str(seed).strip() != "":
        generator = torch.Generator(device=DEVICE).manual_seed(int(seed))

    t0 = time.time()
    out = pipeline(
        prompt=prompt,
        negative_prompt=negative_prompt or None,
        image=image,
        strength=float(strength),
        guidance_scale=float(guidance_scale),
        num_inference_steps=int(steps),
        generator=generator,
    )
    elapsed = time.time() - t0
    active = [(selected_labels[i], selected_weights[i]) for i in range(len(selected_labels)) if selected_labels[i] and selected_labels[i] != "None"]
    lora_tag = "  |  " + ", ".join(f"{l}@{w:.2f}" for l, w in active) if active else ""
    return out.images[0], f"{elapsed:.1f}s on {DEVICE}  |  {sampler}  steps={int(steps)}  cfg={float(guidance_scale):.1f}  str={float(strength):.2f}{lora_tag}"


with gr.Blocks(title="SDXL Image-to-Image Studio") as demo:
    gr.Markdown(
        f"## SDXL Image-to-Image\n"
        f"Model: `{MODEL_ID}` | Device: `{DEVICE}`"
    )
    with gr.Row():
        with gr.Column():
            input_img = gr.Image(type="pil", label="Referenzbild")
            prompt_text = gr.Textbox(
                value="Photorealistic portrait, elegant, 8k, cinematic lighting",
                label="Prompt",
            )
            negative_text = gr.Textbox(
                value=DEFAULT_NEG,
                label="Negative Prompt",
                lines=2,
            )
            with gr.Row():
                strength_slider = gr.Slider(0.1, 1.0, value=0.6, step=0.05, label="Strength")
                guidance_slider = gr.Slider(minimum=1.0, maximum=10.0, value=1.5, step=0.5, label="Guidance Scale (CFG)")
            with gr.Row():
                steps_slider = gr.Slider(minimum=1, maximum=50, value=4, step=1, label="Steps")
                seed_input = gr.Number(value=42, precision=0, label="Seed")
            sampler_dropdown = gr.Dropdown(
                choices=SAMPLER_OPTIONS,
                value="Euler a",
                label="Sampler",
                interactive=True,
            )

            lora_inputs = []

            with gr.Accordion(
                label=(
                    f"LoRA Settings  ({len(COMPATIBLE_LORAS)} compatible, dynamic slots)"
                    if HAS_LORAS else
                    "LoRA Settings  (no compatible .safetensors found)"
                ),
                open=HAS_LORAS,
            ):
                if HAS_LORAS:
                    for idx in range(len(COMPATIBLE_LABELS)):
                        with gr.Row():
                            lora_dropdown = gr.Dropdown(
                                choices=LORA_LABELS,
                                value="None",
                                label=f"LoRA Slot {idx + 1}",
                                interactive=True,
                            )
                            lora_scale = gr.Slider(
                                0.0, 1.0,
                                value=0.75,
                                step=0.05,
                                label=f"LoRA Slot {idx + 1} Weight",
                                interactive=True,
                            )
                        lora_inputs.extend([lora_dropdown, lora_scale])
                else:
                    gr.Markdown(
                        "_Drop `.safetensors` files into `/opt/models/loras/` and restart the app._"
                    )
                if INCOMPATIBLE_LORAS:
                    skipped_lines = [
                        f"- `{label}`: {reason}"
                        for label, reason in sorted(INCOMPATIBLE_LORAS.items())
                    ]
                    gr.Markdown(
                        "### Skipped incompatible LoRAs\n"
                        + "\n".join(skipped_lines)
                    )

            run_btn = gr.Button("Bild transformieren", variant="primary")
        with gr.Column():
            output_img = gr.Image(label="Ergebnis")
            info_box = gr.Textbox(label="Info", interactive=False)

    run_btn.click(
        fn=generate,
        inputs=[
            prompt_text,
            negative_text,
            input_img,
            strength_slider,
            guidance_slider,
            steps_slider,
            seed_input,
            sampler_dropdown,
        ] + lora_inputs,
        outputs=[output_img, info_box],
    )


if __name__ == "__main__":
    demo.queue().launch(server_name=BIND, server_port=PORT, share=False)
