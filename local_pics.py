from gradio_client import Client, handle_file
import shutil
import os
from PIL import Image
import time
import random
import cv2  # Für die Video-Erstellung
import numpy as np
import requests
import json
from openai import OpenAI

# --- KONFIGURATION ---
client = Client("http://127.0.0.1:7860")
base_dir = "video_training_dataset"
img_dir = os.path.join(base_dir, "images")
txt_dir = os.path.join(base_dir, "texts")
os.makedirs(img_dir, exist_ok=True)
os.makedirs(txt_dir, exist_ok=True)

CREATE_PREVIEW_VIDEO = True  # Option: Zeitraffer-Video erstellen
num_images_to_generate = 20  # Anzahl für das Training (20-50 empfohlen)
init_image_path = "test.jpg"

# Qwen API Konfiguration
MOONSHOT_API_KEY = os.getenv("MOONSHOT_API_KEY", "")
if not MOONSHOT_API_KEY and os.path.exists(".moonshot_api"):
    with open(".moonshot_api", "r") as f:
        MOONSHOT_API_KEY = f.read().strip()

# OpenAI-kompatiblen Client für Moonshot initialisieren
moonshot_client = OpenAI(
    api_key=MOONSHOT_API_KEY if MOONSHOT_API_KEY else "dummy",
    base_url="https://api.moonshot.ai/v1"
) if MOONSHOT_API_KEY else None

# Grund-Prompt für Konsistenz (Wichtig für Training!)
# Wir nutzen [trigger], falls du später ein spezielles Wort trainieren willst
base_prompt = "Photorealistic portrait of a stunning woman, black pageboy haircut, striking blue eyes, [trigger]"

if not os.path.exists(init_image_path):
    print(f"Abbruch: {init_image_path} nicht gefunden!")
    exit()


def generate_variations_with_llm(num_variations: int) -> list:
    """Generiert kreative Prompt-Variationen mit der Moonshot (Kimi) API."""
    if not moonshot_client:
        print("⚠️  Keine MOONSHOT_API_KEY gefunden. Verwende Fallback-Variationen.")
        return [
            "cinematic lighting, high detail skin",
            "natural sunlight, outdoor street photography",
            "soft studio light, looking at camera",
            "profile view, dramatic shadows, rim lighting",
            "extreme close-up, highly detailed eyes",
            "medium shot, elegant pose, fashion style",
            "golden hour lighting, warm atmosphere",
            "soft focus background, urban environment"
        ]

    prompt = f"""You are a prompt engineer for AI image generation. Create {num_variations} unique, diverse variations for a portrait photography prompt.
    
Base subject: Photorealistic portrait of a stunning woman, black pageboy haircut, striking blue eyes

Generate {num_variations} different style/lighting/composition variations as comma-separated phrases (e.g., "cinematic lighting, dramatic shadows, rim lighting").
Return ONLY a JSON array of strings, nothing else.

Example format:
["variation 1", "variation 2", "variation 3"]"""

    try:
        print("📡 Frage Moonshot (Kimi) API für Prompt-Variationen...")
        completion = moonshot_client.chat.completions.create(
            model="moonshot-v1-8k",
            messages=[
                {"role": "system", "content": "You are a helpful assistant for AI image prompt generation."},
                {"role": "user", "content": prompt}
            ],
            temperature=0.8
        )
        
        content = completion.choices[0].message.content
        
        # JSON aus dem Response extrahieren
        start_idx = content.find("[")
        end_idx = content.rfind("]") + 1
        if start_idx >= 0 and end_idx > start_idx:
            json_str = content[start_idx:end_idx]
            variations = json.loads(json_str)
            print(f"✅ {len(variations)} Variationen von Kimi erhalten")
            return variations
        else:
            print("⚠️  Kein gültiges JSON in der Response")
            return []
            
    except Exception as e:
        print(f"⚠️  Moonshot API Fehler: {e}. Verwende Fallback.")
        return []


# Generiere Variationen mit LLM
variations = generate_variations_with_llm(num_images_to_generate)
# Fallback wenn LLM keine Variationen liefert
if not variations:
    variations = [
        "cinematic lighting, high detail skin",
        "natural sunlight, outdoor street photography",
        "soft studio light, looking at camera",
        "profile view, dramatic shadows, rim lighting",
        "extreme close-up, highly detailed eyes",
        "medium shot, elegant pose, fashion style",
        "golden hour lighting, warm atmosphere",
        "soft focus background, urban environment"
    ]

generated_files = []

print(f"🚀 Starte Dataset-Generierung: {num_images_to_generate} Bilder...")

for i in range(num_images_to_generate):
    variation = variations[i % len(variations)]
    full_prompt = f"{base_prompt}, {variation}, 8k, highly detailed"
    
    print(f"[{i+1}/{num_images_to_generate}] Generiere: {variation}")
    
    try:
        result = client.predict(
            prompt=full_prompt,
            negative_prompt="anime, cartoon, graphic, text, painting, crayon, graphite, abstract, glitch, deformed, mutated, plastic, surreal, overexposed, blurry, distorted, low quality",
            init_image=handle_file(init_image_path),
            strength=0.55,
            guidance_scale=1.5,
            steps=4,
            seed=random.randint(1, 1000000),
            sampler="Euler a",
            param_8="SDXL Lightning (Speed).safetensors",
            param_9=1.0,
            param_10="Add More Details.safetensors",
            param_11=0.5,
            param_12="Real Dark Contrast.safetensors",
            param_13=0.6,
            param_14="BetterFaces (Anti-AI-Look).safetensors",
            param_15=0.7,
            param_16="Cinematic Photo.safetensors",
            param_17=0.5,
            api_name="/generate",
        )
        
        raw_output = result[0]
        source_path = raw_output.get('path') if isinstance(raw_output, dict) else str(raw_output)

        file_id = f"{i+1:03d}"
        img_path = os.path.join(img_dir, f"train_{file_id}.png")
        txt_path = os.path.join(txt_dir, f"train_{file_id}.txt")
        
        # Als PNG speichern
        with Image.open(source_path) as img:
            img.save(img_path, "PNG")
            generated_files.append(img_path)
            
        # Caption für das Training
        with open(txt_path, "w") as f:
            f.write(full_prompt.replace("[trigger]", "sundancer_style"))
            
        print(f"   -> OK: train_{file_id}.png")

    except Exception as e:
        print(f"   -> Fehler bei Bild {i+1}: {e}")

# --- OPTION: VIDEO PREVIEW ERSTELLEN ---
if CREATE_PREVIEW_VIDEO and generated_files:
    print("\n🎥 Erstelle Video-Vorschau (consistency_check.mp4)...")
    video_path = os.path.join(base_dir, "consistency_check.mp4")
    
    # Erstes Bild für Dimensionen laden
    frame = cv2.imread(generated_files[0])
    height, width, layers = frame.shape
    
    # VideoWriter initialisieren (2 Bilder pro Sekunde für guten Check)
    fourcc = cv2.VideoWriter_fourcc(*'mp4v')
    video = cv2.VideoWriter(video_path, fourcc, 2.0, (width, height))

    for image in generated_files:
        video.write(cv2.imread(image))

    video.release()
    print(f"✅ Video-Vorschau gespeichert unter: {video_path}")

print(f"\n--- FERTIG ---")
print(f"Dataset-Pfad: {os.path.abspath(base_dir)}")
