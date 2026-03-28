#!/bin/bash
# FINALE FIX-LÖSUNG für RTX A6000 Out-of-Memory und Port-Fehler

echo "=== FINALE FIX-LÖSUNG ==="

# 1. Backup
cp /root/setup_remote_v3.sh /root/setup_remote_v3.sh.backup.final

# 2. Finde und korrigiere ALLE Port-Probleme
echo "Korrigiere Port-Parameter..."
# Entferne alle Anführungszeichen um PORT in llama-server Aufrufen
sed -i 's/--port "\${PORT}"/--port \${PORT}/g' /root/setup_remote_v3.sh
sed -i 's/--port "\${SERVICE_PORT}"/--port \${SERVICE_PORT}/g' /root/setup_remote_v3.sh
sed -i 's/--port "${PORT}"/--port ${PORT}/g' /root/setup_remote_v3.sh
sed -i 's/--port "${SERVICE_PORT}"/--port ${SERVICE_PORT}/g' /root/setup_remote_v3.sh

# 3. Batch-Größe korrigieren
echo "Korrigiere Batch-Größe..."
sed -i 's/-b 512/-b 256/g' /root/setup_remote_v3.sh

# 4. Direktes Startskript mit FIXED Port-Parametern
echo "Erstelle direktes Startskript..."
cat > /root/start_qwen_final.sh << 'EOF'
#!/bin/bash
# FINALE Lösung für RTX A6000

# Modell finden
MODEL_DIR="/opt/models/qwen_coder_ablit"
MODEL_FILE=$(find "$MODEL_DIR" -name "*.gguf" -type f 2>/dev/null | head -1)

if [[ -z "$MODEL_FILE" ]]; then
    echo "ERROR: No GGUF model found in $MODEL_DIR"
    ls -la "$MODEL_DIR" 2>/dev/null || echo "Directory does not exist"
    exit 1
fi

echo "=== STARTING QWEN CODER ABLITERATED ==="
echo "Model: $(basename "$MODEL_FILE")"
echo "Port: 8082"
echo "Context: 131072"
echo "Batch: 256"
echo "GPU: RTX A6000 (48GB VRAM)"

# Kill existing server
pkill -f "llama-server.*8082" 2>/dev/null || true
sleep 2

# Start with FIXED parameters - NO quotes around port number!
echo "Starting llama-server..."
nohup llama-server \
  -m "$MODEL_FILE" \
  --host 127.0.0.1 \
  --port 8082 \
  -c 131072 \
  -ngl 999 \
  -ctk turbo3 \
  -ctv turbo3 \
  -fa on \
  -b 256 \
  >/var/log/stack/qwen_final.log 2>&1 &

PID=$!
echo "Server started with PID: $PID"
echo "Log: /var/log/stack/qwen_final.log"

# Wait for startup
echo -n "Waiting for server..."
for i in {1..30}; do
    if curl -s http://127.0.0.1:8082/v1/chat/completions >/dev/null 2>&1 || \
       curl -s http://127.0.0.1:8082/v1/models >/dev/null 2>&1; then
        echo " ✓"
        echo "Server ready at: http://127.0.0.1:8082"
        echo "Test: curl http://127.0.0.1:8082/v1/models"
        exit 0
    fi
    echo -n "."
    sleep 1
done

echo " ✗"
echo "Server failed to start. Check log: /var/log/stack/qwen_final.log"
tail -20 /var/log/stack/qwen_final.log 2>/dev/null || echo "No log file"
exit 1
EOF

chmod +x /root/start_qwen_final.sh

# 5. Teste ob llama-server verfügbar ist
echo "Teste llama-server..."
which llama-server || echo "llama-server nicht gefunden"

# 6. Starte Server
echo "=== STARTE SERVER ==="
/root/start_qwen_final.sh

# 7. Prüfe Status
echo "=== STATUS ==="
sleep 3
echo "Processes:"
ps aux | grep "llama-server.*8082" | grep -v grep || echo "No llama-server process found"

echo "GPU Status:"
nvidia-smi --query-gpu=name,memory.total,memory.used --format=csv

echo "Connection test:"
curl -s http://127.0.0.1:8082/v1/models || echo "Server not reachable"

echo "=== DONE ==="