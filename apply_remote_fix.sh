#!/bin/bash
# Einfaches Skript zum Anwenden der Fixes auf dem Remote-Server
# Kopiere dieses Skript auf den Remote-Server und führe es aus

echo "=== RTX A6000 Out-of-Memory Fix Anwendung ==="
echo "Optimierung für 48GB VRAM (Batch: 256, Context: 131K)"

# 1. Backup der originalen setup_remote_v3.sh
echo "1. Erstelle Backup..."
cp /root/setup_remote_v3.sh /root/setup_remote_v3.sh.backup.$(date +%Y%m%d_%H%M%S)

# 2. Batch-Größe von 512 auf 256 reduzieren
echo "2. Reduziere Batch-Größe von 512 auf 256..."
sed -i 's/turbo_args="-ctk turbo3 -ctv turbo3 -fa on -b 512"/turbo_args="-ctk turbo3 -ctv turbo3 -fa on -b 256"/' /root/setup_remote_v3.sh
sed -i 's/TurboQuant: turbo3)/TurboQuant: turbo3, batch: 256)/' /root/setup_remote_v3.sh

# 3. Optimierte write_onstart_qwen_coder_ablit Funktion
echo "3. Ersetze write_onstart_qwen_coder_ablit Funktion..."
cat > /tmp/new_qwen_func.sh << 'EOF'
write_onstart_qwen_coder_ablit() {
  local model_path="$1"
  # Optimierte Parameter für RTX A6000 (48GB VRAM)
  # Reduzierte Batch-Größe und Context für bessere VRAM-Nutzung
  local ctx_size="${2:-131072}"  # 131K statt 262K für 48GB VRAM
  
  cat > "${ONSTART}" <<ONSTART_EOF
#!/usr/bin/env bash
set -euo pipefail
LOG_DIR="/var/log/stack"
BIND_ADDR="127.0.0.1"
LLAMA_SERVER_BIN="${LLAMA_SERVER_BIN}"
MODEL_PATH="${model_path}"
PORT="${SERVICE_PORT}"
CTX_SIZE="${ctx_size}"

log() { echo "[\$(date '+%H:%M:%S')] \$*"; }
ensure_model_path() {
  if [[ "\$MODEL_PATH" =~ ^(.+)\.part([0-9]+)of([0-9]+)$ ]]; then
    local merged_path="\${BASH_REMATCH[1]}"
    local total_parts="\${BASH_REMATCH[3]}"
    local idx part_path
    if [[ -f "\${merged_path}" ]]; then
      MODEL_PATH="\${merged_path}"
      return 0
    fi
    log "Combining \${total_parts} model parts into \${merged_path}..."
    part_path="\${merged_path}.part1of\${total_parts}"
    if [[ ! -f "\${part_path}" ]]; then
      log "Missing model part: \${part_path}"
      return 1
    fi
    mv "\${part_path}" "\${merged_path}"
    for idx in \$(seq 2 "\${total_parts}"); do
      part_path="\${merged_path}.part\${idx}of\${total_parts}"
      if [[ ! -f "\${part_path}" ]]; then
        log "Missing model part: \${part_path}"
        return 1
      fi
      log "Merge \${idx}/\${total_parts}: \${part_path}"
      cat "\${part_path}" >> "\${merged_path}"
      rm -f "\${part_path}" >/dev/null 2>&1 || true
    done
    MODEL_PATH="\${merged_path}"
  fi
}

mkdir -p "\${LOG_DIR}"
log "=== Starting QWEN_CODER_ABLIT llama.cpp ==="
ensure_model_path

if ! pgrep -af "llama-server.*--port \${PORT}" >/dev/null 2>&1; then
  log "Starting llama-server on \${BIND_ADDR}:\${PORT}..."
  log "Using TurboQuant KV-Cache (turbo3) for reduced VRAM usage"
  log "Optimized for RTX A6000 (48GB VRAM): -b 256 -c \${CTX_SIZE}"
  
  # Optimierte Parameter für 48GB VRAM:
  # -b 256 statt 512 (reduzierter Batch für weniger VRAM)
  # -ctk turbo3 -ctv turbo3 (TurboQuant KV-Cache)
  # -fa on (flash attention)
  nohup stdbuf -oL -eL "\${LLAMA_SERVER_BIN}" \
    -m "\${MODEL_PATH}" \
    --host "\${BIND_ADDR}" \
    --port "\${PORT}" \
    -c "\${CTX_SIZE}" \
    -ngl 999 \
    -ctk turbo3 \
    -ctv turbo3 \
    -fa on \
    -b 256 \
    >"\${LOG_DIR}/qwen_coder_ablit.log" 2>&1 &
  disown
fi

ready=0
for i in \$(seq 1 60); do
  if curl -sf "http://\${BIND_ADDR}:\${PORT}" >/dev/null 2>&1 || \
     curl -sf "http://\${BIND_ADDR}:\${PORT}/health" >/dev/null 2>&1 || \
     curl -sf "http://\${BIND_ADDR}:\${PORT}/v1/models" >/dev/null 2>&1; then
    log "QWEN_CODER_ABLIT ready on port \${PORT}"
    ready=1
    break
  fi
  if (( i == 1 || i % 10 == 0 )); then
    log "QWEN_CODER_ABLIT noch nicht bereit (\${i}s). Log: \${LOG_DIR}/qwen_coder_ablit.log"
  fi
  sleep 1
done

if (( ready == 1 )); then
  log "QWEN_CODER_ABLIT started."
else
  log "QWEN_CODER_ABLIT noch im Start. Pruefe \${LOG_DIR}/qwen_coder_ablit.log"
fi
ONSTART_EOF
  chmod +x "${ONSTART}"
  log "Created ${ONSTART} for qwen_coder_ablit stack (optimized for 48GB VRAM)."
}
EOF

# Alte Funktion entfernen
sed -i '/^write_onstart_qwen_coder_ablit() {/,/^}/d' /root/setup_remote_v3.sh

# Neue Funktion einfügen (vor write_onstart_text_pro)
sed -i '/^write_onstart_text_pro() {/i \
'"$(cat /tmp/new_qwen_func.sh)"'' /root/setup_remote_v3.sh

# 4. Server neu starten
echo "4. Starte Server neu..."
pkill -f "llama-server.*--port 8082" 2>/dev/null || true
sleep 3

echo "5. Starte mit optimierten Parametern..."
cd /root && STACK_TYPE=qwen_coder_ablit bash setup_remote_v3.sh 2>&1 | tail -30

# 6. Status prüfen
echo "6. Prüfe Status..."
sleep 5
echo "=== Laufende Prozesse ==="
ps aux | grep llama-server | grep -v grep
echo "=== Log-Auszug ==="
tail -10 /var/log/stack/qwen_coder_ablit.log 2>/dev/null || echo "Log-Datei existiert nicht"

echo "=== FERTIG ==="
echo "Server sollte jetzt mit optimierten Parametern laufen:"
echo "- Batch-Größe: 256 (statt 512)"
echo "- Context: 131K Token (statt 262K)"
echo "- TurboQuant KV-Cache: turbo3"
echo ""
echo "Teste mit: curl http://127.0.0.1:8082/v1/models"