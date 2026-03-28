# AI Studio

## Zweck
Lokales AI-Studio zum Betrieb von Large Language Models (LLMs) via llama.cpp. Bietet Web-UI und OpenAI-kompatible API für Text- und Bildgenerierung.

## Tech Stack
- **LLM Backend:** llama.cpp (GGUF-Quantisierung)
- **API:** OpenAI API v1 kompatibel (Port 8081, 11436 via Tunnel)
- **Modelle:** Qwen3.5 MoE 122B (Q4_K_M GGUF)
- **Features:**
  - Text-Generierung (text_pro)
  - Bild-zu-Bild (img2img)
  - Streaming-Support
- **Tools:** Python-API-Client, Shell-Skripte für Deployment
- **Integration:** LangChain, OpenAI SDK kompatibel

## Services
- text_pro: 122B Parameter Modell mit 262k Kontext
- API-Endpoints: /v1/chat/completions, /v1/models
