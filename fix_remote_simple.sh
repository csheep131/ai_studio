#!/bin/bash
# Einfaches Fix-Skript für RTX A6000 Out-of-Memory Fehler

echo "=== RTX A6000 Out-of-Memory Fix ==="
echo "Optimierung für 48GB VRAM"

# 1. Backup erstellen
echo "1. Backup erstellen..."
cp /root/setup_remote_v3.sh /root/setup_remote_v3.sh.backup

# 2. Batch-Größe korrigieren (einfacher sed)
echo "2. Batch-Größe korrigieren..."
# Erste sed-Befehl: turbo_args anpassen
sed -i 's/-b 512/-b 256/g' /root/setup_remote_v3.sh

# Zweite sed-Befehl: Log-Nachricht anpassen
sed -i 's/TurboQuant: turbo3)/TurboQuant: turbo3, batch: 256)/g' /root/setup_remote_v3.sh

# 3. Port-Parameter prüfen (wichtig für den stoi Fehler)
echo "3. Port-Parameter prüfen..."
# Stelle sicher dass SERVICE_PORT korrekt gesetzt ist
sed -i 's/--port "\${PORT}"/--port \${PORT}/g' /root/setup_remote_v3.sh

# 4. Direktes Startskript erstellen (falls Setup Probleme hat)
echo "4. Direktes Startskript erstellen..."
cat > /root/start_qwen_fixed.sh << 'EOF'
#!/bin/bash
# Direkter Start mit optimierten Parametern für RTX A6000

# Finde Modell
MODEL_DIR="/opt/models/qwen_coder_ablit"
MODEL_FILE=$(ls "$MODEL_DIR"/*.gguf 2>/dev/null | head -1)

if [[ ! -f "$MODEL_FILE" ]]; then
    echo "Fehler: Kein Modell gefunden in $MODEL_DIR"
    ls -la "$MODEL_DIR" 2>/dev/null || echo "Verzeichnis existiert nicht"
    exit 1
fi

echo "=== Starte Qwen Coder Abliterated ==="
echo "Modell: $(basename "$MODEL_FILE")"
echo "Port: 8082"
echo "Context: 131072 Token"
echo "Batch: 256"
echo "TurboQuant: turbo3 aktiviert"

# Stoppe laufenden Server
pkill -f "llama-server.*--port 8082" 2>/dev/null || true
sleep 2

# Starte mit optimierten Parametern
nohup llama-server \
  -m "$MODEL_FILE" \
  --host "127.0.0.1" \
  --port 8082 \
  -c 131072 \
  -ngl 999 \
  -ctk turbo3 \
  -ctv turbo3 \
  -fa on \
  -b 256 \
  >/var/log/stack/qwen_fixed.log 2>&1 &

SERVER_PID=$!
echo "Server gestartet mit PID: $SERVER_PID"
echo "Log: /var/log/stack/qwen_fixed.log"

# Warte auf Start
echo -n "Warte auf Server..."
for i in {1..30}; do
    if curl -s http://127.0.0.1:8082/v1/models >/dev/null 2>&1; then
        echo " ✓"
        echo "Server bereit: http://127.0.0.1:8082/v1/models"
        exit 0
    fi
    echo -n "."
    sleep 1
done

echo " ✗"
echo "Server nicht gestartet. Prüfe Log: /var/log/stack/qwen_fixed.log"
exit 1
EOF

chmod +x /root/start_qwen_fixed.sh

# 5. Server neu starten
echo "5. Server neu starten..."
# Stoppe alten Server
pkill -f "llama-server.*--port 8082" 2>/dev/null || true
sleep 3

echo "6. Versuche Setup..."
cd /root && STACK_TYPE=qwen_coder_ablit bash setup_remote_v3.sh 2>&1 | grep -A5 -B5 "Starting\|error\|port"

# 7. Falls Setup fehlschlägt, direkter Start
echo "7. Falls Setup fehlschlägt, direkter Start..."
sleep 5
if ! ps aux | grep -q "llama-server.*--port 8082"; then
    echo "Setup fehlgeschlagen, starte direkt..."
    /root/start_qwen_fixed.sh
fi

# 8. Status prüfen
echo "8. Status prüfen..."
sleep 3
echo "=== Prozesse ==="
ps aux | grep llama-server | grep -v grep
echo "=== VRAM Nutzung ==="
nvidia-smi --query-gpu=memory.used,memory.total --format=csv
echo "=== Test ==="
curl -s http://127.0.0.1:8082/v1/models || echo "Server nicht erreichbar"

echo "=== FERTIG ==="