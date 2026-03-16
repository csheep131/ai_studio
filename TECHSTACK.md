# TECHSTACK

## Überblick

AI Studio verwaltet vier aktive Remote-Stacks auf Vast.ai:

- `text`
- `text_pro`
- `image`
- `video`

Alle Stacks mieten standardmäßig einzelne GPU-Instanzen auf Vast.ai und verwenden als Basis-Container `nvidia/cuda:12.4.1-cudnn-devel-ubuntu22.04`.

## Gemeinsame Architektur

- Orchestrierung lokal über [studio.sh](/home/schaf/projects/ai_studio/studio.sh), [manage_v7_fixed.sh](/home/schaf/projects/ai_studio/manage_v7_fixed.sh) und [vast.py](/home/schaf/projects/ai_studio/vast.py)
- Zentrale Stack-Konfiguration in [stacks.yaml](/home/schaf/projects/ai_studio/stacks.yaml)
- Remote-Setup auf der Instanz über [setup_remote_v3.sh](/home/schaf/projects/ai_studio/setup_remote_v3.sh)
- Lokale Stack-Zuordnung über `.vast_instance_<stack>`
- Hugging Face Token aus `.env` via `HF_TOKEN` oder `HUGGINGFACE_HUB_TOKEN`
- Vast API-Key aus `.vastai_key` oder `~/.config/vastai/vast_api_key`

## Stack: `text`

- Zweck: allgemeiner LLM-Chat
- UI-Label: `llama.cpp Text`
- Port remote/lokal: `8080`
- Runtime: `llama.cpp` / `llama-server`
- Modellformat: GGUF
- Standardmodell: `cesarsal1nas/Huihui-Qwen3.5-35B-A3B-abliterated-Q4_K_M-GGUF`
- Model-Hint: `huihui-qwen3.5-35b-a3b-abliterated-Q4_K_M.gguf`
- GPU-Ziel: `A6000|A100|H100|H200|L40S`
- Mindest-VRAM: `49152 MB`
- Remote-Komponenten:
  - `/onstart.sh`
  - `/etc/stack_manifest.json`
  - `/opt/models/text`
  - `/var/log/stack/text.log`

## Stack: `text_pro`

- Zweck: großes Coding-/Reasoning-Modell
- UI-Label: `llama.cpp Pro (H100+)`
- Port remote/lokal: `8081`
- Runtime: `llama.cpp` / `llama-server`
- Modellformat: GGUF
- Standardmodell: `huihui-ai/Huihui-Qwen3.5-122B-A10B-abliterated-GGUF`
- Model-Hint: `Q4_K-GGUF`
- GPU-Ziel: `H100|H200|B200|B100|GH200`
- Mindest-VRAM: `81920 MB`
- Disk: `100 GB`
- Besonderheiten:
  - H100+-Prüfung im Remote-Setup
  - GGUF-Part-Merge nur für echte `.part1ofN`-Dateien
  - Split-GGUF-Shards wie `-00001-of-00008.gguf` werden nativ verwendet
- Remote-Komponenten:
  - `/onstart.sh`
  - `/etc/stack_manifest.json`
  - `/opt/models/text_pro`
  - `/var/log/stack/text_pro.log`

## Stack: `image`

- Zweck: Text-zu-Bild UI
- UI-Label: `Gradio Image UI`
- Port remote/lokal: `7860`
- Runtime: Python-Venv + Gradio + Diffusers
- Standardmodell: `stabilityai/stable-diffusion-xl-base-1.0`
- GPU-Ziel: `4090|3090|A5000|A6000|L40S|A40|A100|H100`
- Mindest-VRAM: `24000 MB`
- Wichtige Python-Pakete:
  - `torch`
  - `diffusers`
  - `transformers`
  - `accelerate`
  - `safetensors`
  - `gradio`
- Remote-Komponenten:
  - `/onstart.sh`
  - `/opt/generative-ui/app.py`
  - `/opt/generative-ui/venv`
  - `/var/log/stack/image.log`

## Stack: `video`

- Zweck: Video-UI für Wan 2.1
- UI-Label: `Wan2.1 Video Studio`
- Port remote/lokal: `7861`
- Runtime: Python-Venv + Gradio + Diffusers
- Standardmodell: `Wan-AI/Wan2.1-T2V-14B-Diffusers`
- GPU-Ziel: `H100|H200|A100|A800`
- Mindest-VRAM: `81920 MB`
- Wichtige Python-Pakete:
  - `torch`
  - `diffusers`
  - `transformers`
  - `accelerate`
  - `safetensors`
  - `gradio`
  - `flash-attn` optional
- Remote-Komponenten:
  - `/onstart.sh`
  - `/opt/video-studio/video_ui.py`
  - `/opt/video-studio/venv`
  - `/var/log/stack/video.log`

## Lokale Steuerung

- Interaktive Oberfläche: [studio.sh](/home/schaf/projects/ai_studio/studio.sh)
- Direkte Stack-Befehle: [manage_v7_fixed.sh](/home/schaf/projects/ai_studio/manage_v7_fixed.sh)
- Vast-Backend und Health/SSH/Setup-Logik: [vast.py](/home/schaf/projects/ai_studio/vast.py)

## Wichtige Dateien

- Konfiguration: [stacks.yaml](/home/schaf/projects/ai_studio/stacks.yaml)
- Remote-Setup: [setup_remote_v3.sh](/home/schaf/projects/ai_studio/setup_remote_v3.sh)
- Interaktive UI: [studio.sh](/home/schaf/projects/ai_studio/studio.sh)
- CLI-Manager: [manage_v7_fixed.sh](/home/schaf/projects/ai_studio/manage_v7_fixed.sh)
- Vast-Orchestrierung: [vast.py](/home/schaf/projects/ai_studio/vast.py)
