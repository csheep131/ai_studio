#!/usr/bin/env python3
"""
FLUX.1 Text-to-Image Gradio UI
Generiert Bilder aus Text-Prompts ohne init_image.
"""

import gradio as gr
import torch
from diffusers import FluxPipeline
from huggingface_hub import login
import os
import tempfile

# Hugging Face Login (falls Token vorhanden)
hf_token = os.getenv("HF_TOKEN")
if hf_token:
    login(token=hf_token)

# Modell laden
MODEL_ID = os.getenv("MODEL_ID", "black-forest-labs/FLUX.2-dev")

print(f"🚀 Lade {MODEL_ID}...")

# Pipeline initialisieren
pipe = FluxPipeline.from_pretrained(
    MODEL_ID,
    torch_dtype=torch.bfloat16,
    device_map="auto" if torch.cuda.is_device_available() else None,
)

if torch.cuda.is_available():
    pipe = pipe.to("cuda")

# LoRA Cache
lora_cache = {}

def load_lora(name, url):
    """Lädt ein LoRA und cached es."""
    if name in lora_cache:
        return lora_cache[name]
    
    print(f"📥 Lade LoRA: {name}")
    from huggingface_hub import hf_hub_download
    local_path = hf_hub_download(repo_id=url.split("/resolve/")[0], filename=url.split("/")[-1])
    
    # LoRA Gewicht laden
    state_dict = torch.load(local_path, map_location="cpu", weights_only=True)
    lora_cache[name] = state_dict
    print(f"✅ LoRA geladen: {name}")
    return state_dict

# Verfügbare LoRAs aus stacks.yaml (hier hard-coded für einfache Bereitstellung)
LORA_CONFIG = [
    {"name": "None", "url": None},
    {"name": "FLUX Realism", "url": "https://huggingface.co/alvdansen/sonata-sd3-fp8/resolve/main/dream_shine_flux_lora.safetensors"},
    {"name": "Detail Enhancer", "url": "https://huggingface.co/shadowl1th/FLUX.1-dev-LoRA-Add_More_Details/resolve/main/add_more_details_flux.safetensors"},
    {"name": "Cinematic Look", "url": "https://huggingface.co/shadowl1th/FLUX.1-dev-LoRA-Cinematic/resolve/main/cinematic_flux.safetensors"},
]

LORA_NAMES = [l["name"] for l in LORA_CONFIG]

def generate_image(
    prompt,
    negative_prompt,
    lora_1, lora_1_weight,
    lora_2, lora_2_weight,
    lora_3, lora_3_weight,
    lora_4, lora_4_weight,
    lora_5, lora_5_weight,
    steps,
    guidance_scale,
    seed,
    width,
    height
):
    """Generiert ein Bild aus einem Text-Prompt."""
    
    # LoRAs anwenden
    active_loras = []
    for lora_name, lora_weight in [
        (lora_1, lora_1_weight),
        (lora_2, lora_2_weight),
        (lora_3, lora_3_weight),
        (lora_4, lora_4_weight),
        (lora_5, lora_5_weight),
    ]:
        if lora_name != "None" and lora_name:
            lora_config = next((l for l in LORA_CONFIG if l["name"] == lora_name), None)
            if lora_config and lora_config["url"]:
                try:
                    lora_path = lora_config["url"].split("/resolve/")[0].replace("https://huggingface.co/", "")
                    lora_filename = lora_config["url"].split("/")[-1]
                    pipe.load_lora_weights(lora_path, weight_name=lora_filename, adapter_name=lora_name.lower().replace(" ", "_"))
                    pipe.set_adapters([lora_name.lower().replace(" ", "_")], [lora_weight])
                    active_loras.append(lora_name)
                except Exception as e:
                    print(f"⚠️ LoRA {lora_name} konnte nicht geladen werden: {e}")
    
    if active_loras:
        print(f"🎨 Aktive LoRAs: {', '.join(active_loras)}")
    
    # Generator für reproduzierbare Ergebnisse
    generator = torch.Generator(device="cuda" if torch.cuda.is_available() else "cpu").manual_seed(seed)
    
    # Bild generieren
    print(f"📝 Prompt: {prompt[:100]}...")
    print(f"⚙️ Steps: {steps}, Guidance: {guidance_scale}, Size: {width}x{height}")
    
    image = pipe(
        prompt=prompt,
        negative_prompt=negative_prompt if negative_prompt else None,
        num_inference_steps=steps,
        guidance_scale=guidance_scale,
        generator=generator,
        width=width,
        height=height,
    ).images[0]
    
    # LoRAs entladen
    pipe.unload_lora_weights()
    
    # Bild in temporäre Datei speichern
    temp_file = tempfile.NamedTemporaryFile(suffix=".png", delete=False)
    image.save(temp_file.name, "PNG")
    
    info = f"Prompt: {prompt}\nSize: {width}x{height} | Steps: {steps} | Guidance: {guidance_scale} | Seed: {seed}"
    if active_loras:
        info += f"\nLoRAs: {', '.join(active_loras)}"
    
    return temp_file.name, info


# Gradio UI
with gr.Blocks(title="FLUX.2 Text-to-Image", theme=gr.themes.Soft()) as demo:
    gr.Markdown("# 🎨 FLUX.2 Text-to-Image Studio")
    gr.Markdown("Generiere hochwertige Bilder aus Text-Prompts mit FLUX.2-dev")
    
    with gr.Row():
        with gr.Column(scale=1):
            gr.Markdown("### 📝 Prompt")
            prompt = gr.Textbox(
                label="Prompt",
                placeholder="Beschreibe das Bild, das du generieren möchtest...",
                value="Photorealistic portrait of a stunning woman, elegant dress, cinematic lighting, highly detailed",
                lines=3
            )
            negative_prompt = gr.Textbox(
                label="Negative Prompt",
                placeholder="Was soll NICHT im Bild erscheinen...",
                value="ugly, deformed, noisy, blurry, low quality, distorted, disfigured, bad anatomy, extra limbs",
                lines=2
            )
            
            gr.Markdown("### 🎭 LoRAs")
            with gr.Row():
                lora_1 = gr.Dropdown(choices=LORA_NAMES, value="None", label="LoRA 1")
                lora_1_weight = gr.Slider(0, 1, value=0.75, step=0.05, label="Gewicht")
            with gr.Row():
                lora_2 = gr.Dropdown(choices=LORA_NAMES, value="None", label="LoRA 2")
                lora_2_weight = gr.Slider(0, 1, value=0.75, step=0.05, label="Gewicht")
            with gr.Row():
                lora_3 = gr.Dropdown(choices=LORA_NAMES, value="None", label="LoRA 3")
                lora_3_weight = gr.Slider(0, 1, value=0.75, step=0.05, label="Gewicht")
            with gr.Row():
                lora_4 = gr.Dropdown(choices=LORA_NAMES, value="None", label="LoRA 4")
                lora_4_weight = gr.Slider(0, 1, value=0.75, step=0.05, label="Gewicht")
            with gr.Row():
                lora_5 = gr.Dropdown(choices=LORA_NAMES, value="None", label="LoRA 5")
                lora_5_weight = gr.Slider(0, 1, value=0.75, step=0.05, label="Gewicht")
            
            gr.Markdown("### ⚙️ Einstellungen")
            steps = gr.Slider(1, 50, value=28, step=1, label="Inference Steps")
            guidance_scale = gr.Slider(1, 10, value=3.5, step=0.5, label="Guidance Scale")
            seed = gr.Number(value=42, precision=0, label="Seed (-1 für zufällig)")
            with gr.Row():
                width = gr.Slider(256, 1536, value=1024, step=64, label="Breite")
                height = gr.Slider(256, 1536, value=1024, step=64, label="Höhe")
            
            generate_btn = gr.Button("🚀 Generieren", variant="primary", size="lg")
        
        with gr.Column(scale=1):
            gr.Markdown("### 🖼️ Ergebnis")
            output_image = gr.Image(label="Generiertes Bild", type="filepath")
            output_info = gr.Textbox(label="Info", lines=3)
    
    # Event Handler
    generate_btn.click(
        fn=generate_image,
        inputs=[
            prompt, negative_prompt,
            lora_1, lora_1_weight, lora_2, lora_2_weight, lora_3, lora_3_weight,
            lora_4, lora_4_weight, lora_5, lora_5_weight,
            steps, guidance_scale, seed, width, height
        ],
        outputs=[output_image, output_info]
    )
    
    # Beispiele
    gr.Markdown("### 📚 Beispiele")
    gr.Examples(
        examples=[
            ["Photorealistic portrait of a stunning woman, black pageboy haircut, striking blue eyes, cinematic lighting, 8k, highly detailed"],
            ["Majestic landscape, snow-capped mountains, golden hour, dramatic clouds, photorealistic, 8k"],
            ["Futuristic cityscape at night, neon lights, flying cars, cyberpunk style, highly detailed"],
            ["Cozy cabin in the forest, autumn leaves, warm lighting, photorealistic, 8k"],
            ["Elegant fashion portrait, studio lighting, high detail skin texture, professional photography"],
        ],
        inputs=[prompt]
    )

if __name__ == "__main__":
    demo.queue(max_size=10).launch(server_name="0.0.0.0", server_port=7863)
