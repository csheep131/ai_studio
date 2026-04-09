#!/bin/bash

# =============================================
#  Huihui-Qwen3.5-27B-Claude-4.6-Opus (Q4_K_M)
# =============================================

echo "=== Starte Setup für RTX 6000 Ada ==="

# 1. Ollama stoppen (VRAM freimachen)
echo "--- Stoppe Ollama ---"
pkill -9 ollama 2>/dev/null || true

# 2. Build-Tools (falls noch nicht da)
echo "--- Installiere Build-Tools (falls nötig) ---"
apt-get update -qq && apt-get install -y -qq build-essential git cmake libcurl4-openssl-dev libicu-dev

# 3. llama.cpp klonen + nur bei Bedarf bauen
cd "$(dirname "$0")"  # Script-Ordner als Basis

if [ ! -d "llama.cpp" ]; then
    echo "--- Klone llama.cpp ---"
    git clone https://github.com/ggerganov/llama.cpp
fi

cd llama.cpp

# Nur neu bauen, wenn die Binary noch nicht existiert
if [ ! -f "build/bin/llama-cli" ]; then
    echo "--- Kompiliere llama.cpp mit CUDA (Compute 8.9) ---"
    mkdir -p build
    cd build
    cmake .. -DGGML_CUDA=ON -DCMAKE_CUDA_ARCHITECTURES=89
    cmake --build . --config Release -j$(nproc)
    cd ..
else
    echo "--- llama-cli schon gebaut → überspringe Kompilierung ---"
fi

cd ..  # zurück in den Hauptordner

# 4. Neues Modell herunterladen
MODEL_URL="https://huggingface.co/mradermacher/Huihui-Qwen3.5-27B-Claude-4.6-Opus-abliterated-GGUF/resolve/main/Huihui-Qwen3.5-27B-Claude-4.6-Opus-abliterated.Q4_K_M.gguf"
MODEL_PATH="Huihui-Qwen3.5-27B-Claude-4.6-Opus-abliterated.Q4_K_M.gguf"

if [ ! -f "$MODEL_PATH" ]; then
    echo "--- Lade Modell herunter (ca. 15-18 GB) ---"
    wget -O "$MODEL_PATH" "$MODEL_URL" || {
        echo "❌ Download fehlgeschlagen!"
        exit 1
    }
else
    echo "--- Modell bereits vorhanden ---"
fi

# 5. Modell starten (optimiert für deine 48 GB RTX 6000 Ada)
echo "--- Starte Modell mit optimiertem KV-Cache (Flash Attention ON) ---"
./llama.cpp/build/bin/llama-cli \
    -m "$MODEL_PATH" \
    -ngl 99 \
    -fa on \                    # ← jetzt korrekt mit "on"
    -c 32768 \
    --rope-freq-base 1000000 \
    --rope-freq-scale 1 \
    -p "Du bist ein hilfreicher, direkter und kreativer Assistent." \
    --interactive-first

echo "✅ Fertig!"
