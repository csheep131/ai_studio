#!/bin/bash
# Optimiertes Startskript für Qwen Coder Abliterated auf RTX A6000 (48GB VRAM)

set -euo pipefail

# Parameter für RTX A6000 (48GB VRAM)
MODEL_PATH="/opt/models/qwen_coder_ablit/Qwen3-Coder-Next-abliterated-Q4_K_M.gguf"
BIND_ADDR="127.0.0.1"
PORT="8082"
CTX_SIZE="131072"  # 131K statt 262K für 48GB VRAM
BATCH_SIZE="256"   # Reduziert von 512 für weniger VRAM

# Überprüfe ob llama-server verfügbar ist
LLAMA_SERVER_BIN="$(command -v llama-server 2>/dev/null || echo "/opt/llama.cpp/build/bin/llama-server")"
if [[ ! -x "$LLAMA_SERVER_BIN" ]]; then
    echo "✗ llama-server nicht gefunden: $LLAMA_SERVER_BIN"
    echo "Bitte installiere llama-cpp-turboquant-cuda zuerst"
    exit 1
fi

# Überprüfe ob Modell existiert
if [[ ! -f "$MODEL_PATH" ]]; then
    echo "✗ Modell nicht gefunden: $MODEL_PATH"
    echo "Bitte Modell herunterladen oder Pfad anpassen"
    exit 1
fi

# Starte den Server mit optimierten Parametern
echo "=== Starte QWEN_CODER_ABLIT llama.cpp ==="
echo "Modell: $(basename "$MODEL_PATH")"
echo "Port: $PORT"
echo "Context: $CTX_SIZE Token"
echo "Batch: $BATCH_SIZE"
echo "TurboQuant: turbo3 aktiviert"
echo "GPU: RTX A6000 (48GB VRAM optimiert)"

# Starte den Server
nohup stdbuf -oL -eL "$LLAMA_SERVER_BIN" \
  -m "$MODEL_PATH" \
  --host "$BIND_ADDR" \
  --port "$PORT" \
  -c "$CTX_SIZE" \
  -ngl 999 \
  -ctk turbo3 \
  -ctv turbo3 \
  -fa on \
  -b "$BATCH_SIZE" \
  >"/tmp/qwen_coder_ablit.log" 2>&1 &

SERVER_PID=$!
echo "Server gestartet mit PID: $SERVER_PID"
echo "Log: /tmp/qwen_coder_ablit.log"

# Warte auf Server-Start
echo -n "Warte auf Server-Bereitschaft..."
for i in {1..30}; do
    if curl -s "http://$BIND_ADDR:$PORT" >/dev/null 2>&1 || \
       curl -s "http://$BIND_ADDR:$PORT/health" >/dev/null 2>&1 || \
       curl -s "http://$BIND_ADDR:$PORT/v1/models" >/dev/null 2>&1; then
        echo " ✓"
        echo "Server bereit auf http://$BIND_ADDR:$PORT"
        echo "Verwende: curl http://$BIND_ADDR:$PORT/v1/models"
        exit 0
    fi
    echo -n "."
    sleep 1
done

echo " ✗"
echo "Server nicht innerhalb von 30 Sekunden gestartet"
echo "Prüfe Log: /tmp/qwen_coder_ablit.log"
kill $SERVER_PID 2>/dev/null || true
exit 1