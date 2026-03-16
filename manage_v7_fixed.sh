#!/usr/bin/env bash
set -Eeuo pipefail

# manage_v7_fixed.sh - UI für Stack-Management
# Nutzt vast.py als Backend und stacks.yaml als zentrale Konfiguration

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VAST_PY="${SCRIPT_DIR}/vast.py"
STACKS_YAML="${SCRIPT_DIR}/stacks.yaml"
VAST_KEY_FILE="${SCRIPT_DIR}/.vastai_key"
ENV_FILE="${SCRIPT_DIR}/.env"
HF_TOKEN_FILE="${SCRIPT_DIR}/.hf_token"
REMOTE_SETUP="${SCRIPT_DIR}/setup_remote_v3.sh"
IMAGE_APP_SOURCE="${SCRIPT_DIR}/ap_img2img.py"

# ---------- UI ----------
if [[ -t 1 ]]; then
  RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; BLUE=''; BOLD=''; NC=''
fi

print_info()   { echo -e "${BLUE}▶${NC} $*"; }
print_ok()     { echo -e "${GREEN}✓${NC} $*"; }
print_warn()   { echo -e "${YELLOW}⚠${NC} $*"; }
print_err()    { echo -e "${RED}✗${NC} $*"; }
die()          { print_err "$*"; exit 1; }
need()         { command -v "$1" >/dev/null 2>&1 || die "Fehlender Befehl: $1"; }

# ---------- checks ----------
need bash
need python3
need jq

load_env_file() {
  if [[ -f "${ENV_FILE}" ]]; then
    set -a
    # shellcheck disable=SC1090
    source "${ENV_FILE}"
    set +a
  fi
}

load_env_file

resolve_hf_token() {
  local token=""
  if [[ -f "${HF_TOKEN_FILE}" ]]; then
    token="$(tr -d '\r\n' < "${HF_TOKEN_FILE}")"
  fi
  if [[ -z "${token}" ]]; then
    token="${HF_TOKEN:-${HUGGINGFACE_HUB_TOKEN:-}}"
  fi
  printf '%s' "${token}"
}

export_project_hf_token() {
  local token
  token="$(resolve_hf_token)"
  if [[ -n "${token}" ]]; then
    export HF_TOKEN="${token}"
    export HUGGINGFACE_HUB_TOKEN="${token}"
  fi
}

export_project_hf_token

get_image_expected_lora_filenames() {
  python3 - <<'PY'
import json
import os
from urllib.parse import urlparse
import yaml

cfg = yaml.safe_load(open("stacks.yaml"))
items = cfg.get("stacks", {}).get("image", {}).get("loras", []) or []
for item in items:
    if isinstance(item, str):
        url = item.strip()
        if not url:
            continue
        name = os.path.basename(urlparse(url).path) or "lora.safetensors"
        if "." not in os.path.basename(name):
            name = f"{name}.safetensors"
        print(name)
    elif isinstance(item, dict):
        url = str(item.get("url", "")).strip()
        if not url:
            continue
        name = str(item.get("filename") or item.get("name") or os.path.basename(urlparse(url).path) or "lora.safetensors").strip()
        if name:
            if "." not in os.path.basename(name):
                name = f"{name}.safetensors"
            print(name)
PY
}

image_assets_need_refresh() {
  local stack="$1"
  [[ "$stack" == "image" ]] || return 1
  [[ -n "${INSTANCE_IP:-}" && -n "${INSTANCE_PORT:-}" ]] || return 1

  local local_app_hash=""
  [[ -f "${IMAGE_APP_SOURCE}" ]] && local_app_hash="$(sha256sum "${IMAGE_APP_SOURCE}" | awk '{print $1}')"

  local remote_info remote_app_hash expected missing=0
  remote_info=$(ssh -T -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o LogLevel=ERROR -o ConnectTimeout=8 -p "${INSTANCE_PORT}" "root@${INSTANCE_IP}" \
    "bash --noprofile --norc -lc 'sha256sum /opt/generative-ui/app.py 2>/dev/null | awk \"{print \\$1}\"; echo ---LORAS---; if [[ -d /opt/models/loras ]]; then find /opt/models/loras -maxdepth 1 -type f -printf \"%f\n\" | sort; fi'" \
    2>/dev/null || true)

  [[ -n "${remote_info}" ]] || return 0
  remote_app_hash="$(printf '%s\n' "${remote_info}" | sed -n '1p')"
  if [[ -n "${local_app_hash}" && "${local_app_hash}" != "${remote_app_hash}" ]]; then
    return 0
  fi

  while IFS= read -r expected; do
    [[ -n "${expected}" ]] || continue
    if ! printf '%s\n' "${remote_info}" | awk 'seen{print} /^---LORAS---$/{seen=1}' | grep -Fxq "${expected}"; then
      missing=1
      break
    fi
  done < <(get_image_expected_lora_filenames)

  [[ "${missing}" -eq 1 ]] && return 0
  return 1
}

# Lade stacks.yaml für Stack-Liste
get_available_stacks() {
  python3 -c "import yaml; c=yaml.safe_load(open('${STACKS_YAML}')); print(' '.join(c.get('stacks', {}).keys()))"
}

is_valid_stack() {
  local stack="$1"
  local stacks
  stacks=$(get_available_stacks)
  [[ " ${stacks} " =~ " ${stack} " ]]
}

# ---------- State Management ----------
state_file_for() { echo "${SCRIPT_DIR}/.vast_instance_${1}"; }
has_state()      { [[ -f "$(state_file_for "$1")" ]]; }

load_state() {
  local stack="$1"
  local sf="$(state_file_for "$stack")"
  if [[ ! -f "$sf" ]]; then
    return 1
  fi
  source "$sf" >/dev/null 2>&1 || true
  : "${INSTANCE_ID:?}" "${INSTANCE_IP:?}" "${INSTANCE_PORT:?}"
  export INSTANCE_ID INSTANCE_IP INSTANCE_PORT STACK
  return 0
}

save_state() {
  local stack="$1" iid="$2" ip="$3" port="$4"
  local sf="$(state_file_for "$stack")"
  cat > "$sf" <<EOF_STATE
INSTANCE_ID="${iid}"
INSTANCE_IP="${ip}"
INSTANCE_PORT="${port}"
STACK="${stack}"
EOF_STATE
  chmod 600 "$sf"
  print_ok "State gespeichert: ${sf}"
}

clear_state() {
  local stack="$1"
  local sf="$(state_file_for "$stack")"
  if [[ -f "$sf" ]]; then
    rm -f "$sf"
    print_ok "Lokale State-Datei entfernt: ${sf}"
  else
    print_warn "Keine lokale State-Datei für ${stack}."
  fi
}

# ---------- Helper functions ----------

require_valid_stack() {
  local stack="$1"
  is_valid_stack "$stack" || die "Ungültiger Stack: ${stack} (verfügbar: $(get_available_stacks))"
}

require_state() {
  local stack="$1"
  load_state "$stack" || die "Keine State-Datei für ${stack}. Bitte zuerst 'rent' oder 'use' ausführen."
}

# Auto-correct: Wenn Instanz nicht existiert, suche nach laufender Instanz
auto_correct_instance_id() {
  local stack="$1"
  require_state "$stack"
  
  print_info "Prüfe Instanz ${INSTANCE_ID}..."
  if python3 "${VAST_PY}" instance-status "${INSTANCE_ID}" --json 2>/dev/null | jq -e '.exists == true' >/dev/null; then
    print_ok "Instanz existiert."
    return 0
  fi
  
  print_warn "Gespeicherte Instanz ${INSTANCE_ID} existiert nicht."
  print_warn "Automatische Adoption ist deaktiviert, um falsche Stack-Zuordnungen zu vermeiden."
  print_warn "Bitte Instanz manuell zuweisen oder State löschen und neu mieten:"
  echo "  ./manage_v7_fixed.sh use ${stack} <id>"
  echo "  Oder alle löschen: ./manage_v7_fixed.sh delete ${stack} --remote"
  return 1
}

require_instance_exists() {
  local stack="$1"
  require_state "$stack"
  
  # Auto-correct versuchen
  if ! auto_correct_instance_id "$stack"; then
    return 1
  fi
  
  # State neu laden
  load_state "$stack" || return 1
  
  print_info "Prüfe Remote-Instanz ${INSTANCE_ID}..."
  if python3 "${VAST_PY}" instance-status "${INSTANCE_ID}" --json 2>/dev/null | jq -e '.exists == true' >/dev/null; then
    print_ok "Remote-Instanz existiert."
    return 0
  else
    print_err "Remote-Instanz ${INSTANCE_ID} existiert nicht (mehr)."
    return 1
  fi
}

require_instance_running() {
  local stack="$1"
  require_instance_exists "$stack"
  print_info "Prüfe Status der Instanz ${INSTANCE_ID}..."
  if python3 "${VAST_PY}" instance-status "${INSTANCE_ID}" --json 2>/dev/null | jq -e '.running == true' >/dev/null; then
    print_ok "Instanz läuft."
    return 0
  else
    print_warn "Instanz ${INSTANCE_ID} ist nicht running."
    return 1
  fi
}

ensure_instance_running() {
  local stack="$1"
  require_state "$stack"
  if require_instance_running "$stack"; then
    return 0
  fi
  print_info "Starte Instanz ${INSTANCE_ID}..."
  if vastai start instance "${INSTANCE_ID}" >/dev/null 2>&1; then
    print_ok "Startbefehl gesendet."
    local max=30 interval=2 i=0
    for ((i=0; i<max; i++)); do
      if python3 "${VAST_PY}" instance-status "${INSTANCE_ID}" --json 2>/dev/null | jq -e '.running == true' >/dev/null; then
        print_ok "Instanz läuft jetzt."
        return 0
      fi
      sleep "$interval"
    done
    print_err "Instanz ist nach $((max*interval)) Sekunden nicht running."
    return 1
  else
    print_err "Start fehlgeschlagen."
    return 1
  fi
}

ensure_ssh_reachable() {
  local stack="$1"
  require_state "$stack"
  print_info "Prüfe SSH-Erreichbarkeit ${INSTANCE_IP}:${INSTANCE_PORT}..."
  if python3 "${VAST_PY}" ssh-check "$stack" --json 2>/dev/null | jq -e '.ssh_reachable == true' >/dev/null; then
    print_ok "SSH erreichbar."
    return 0
  else
    print_warn "SSH nicht erreichbar."
    return 1
  fi
}

wait_for_ssh() {
  local stack="$1" timeout="${2:-180}" interval="${3:-5}"
  require_state "$stack"
  print_info "Warte auf SSH (max ${timeout}s)..."
  local start_time=$(date +%s)
  while (( $(date +%s) - start_time < timeout )); do
    if ensure_ssh_reachable "$stack"; then
      print_ok "SSH erreichbar."
      return 0
    fi
    sleep "$interval"
  done
  print_err "SSH nach ${timeout}s nicht erreichbar."
  return 1
}

remote_log_file_for_stack() {
  local stack="$1"
  case "$stack" in
    text|text_pro)
      echo "/var/log/stack/${stack}.log"
      ;;
    image)
      echo "/var/log/stack/image.log"
      ;;
    video|video_i2v)
      echo "/var/log/stack/video.log"
      ;;
    video_lora)
      echo "/var/log/stack/video_lora.log"
      ;;
    *)
      echo "/var/log/stack/${stack}.log"
      ;;
  esac
}

start_remote_log_stream() {
  local stack="$1"
  local log_file
  log_file="$(remote_log_file_for_stack "$stack")"
  print_info "Live-Log: ${log_file}"
  ssh -o StrictHostKeyChecking=no -o ConnectTimeout=15 -o ServerAliveInterval=30 \
    -p "${INSTANCE_PORT}" root@"${INSTANCE_IP}" \
    "bash --noprofile --norc -lc 'log_file=\"${log_file}\"; for i in \$(seq 1 120); do [[ -f \"\$log_file\" ]] && break; sleep 1; done; if [[ -f \"\$log_file\" ]]; then tail -n 40 -f \"\$log_file\"; else echo \"[remote-log] Logdatei noch nicht vorhanden: \$log_file\"; fi'" \
    &
  REMOTE_LOG_TAIL_PID=$!
}

stop_remote_log_stream() {
  local pid="${1:-${REMOTE_LOG_TAIL_PID:-}}"
  [[ -n "${pid}" ]] || return 0
  kill "${pid}" >/dev/null 2>&1 || true
  wait "${pid}" 2>/dev/null || true
  unset REMOTE_LOG_TAIL_PID
}

print_remote_log_snapshot() {
  local stack="$1"
  local log_file
  log_file="$(remote_log_file_for_stack "$stack")"
  print_warn "Letzte Zeilen aus ${log_file}:"
  ssh -o StrictHostKeyChecking=no -o ConnectTimeout=15 -o ServerAliveInterval=30 \
    -p "${INSTANCE_PORT}" root@"${INSTANCE_IP}" \
    "bash --noprofile --norc -lc 'if [[ -f \"${log_file}\" ]]; then tail -n 80 \"${log_file}\"; else echo \"[remote-log] Keine Logdatei: ${log_file}\"; fi'" \
    || true
}

stack_health() {
  local stack="$1"
  require_valid_stack "$stack"
  print_info "Health-Check für ${stack}..."
  python3 "${VAST_PY}" health "$stack" --json 2>/dev/null || echo '{}'
}

is_stack_ready() {
  local stack="$1"
  stack_health "$stack" | jq -e '.ready == true' >/dev/null 2>&1
}

ensure_stack_setup() {
  local stack="$1"
  require_state "$stack"
  ensure_instance_running "$stack"
  wait_for_ssh "$stack" 300 5
  print_info "Prüfe Setup für ${stack}..."

  if [[ "${FORCE_MODEL_REINSTALL:-0}" == "1" ]]; then
    print_warn "Erzwinge Modell-Neuinstallation."
  else

    local health_json
    local model_match_state="unknown"
    local image_assets_stale="false"
    health_json=$(python3 "${VAST_PY}" health "$stack" --json 2>/dev/null || echo '{}')
    if [[ "$stack" == "image" ]] && image_assets_need_refresh "$stack"; then
      image_assets_stale="true"
      print_warn "Image-App oder konfigurierte LoRAs fehlen/abweichen. Führe Setup neu aus..."
    fi
    if echo "$health_json" | jq -e '.checks.manifest_model.match == true' >/dev/null 2>&1; then
      model_match_state="true"
      if [[ "${image_assets_stale}" != "true" ]]; then
        print_ok "Setup bereits vorhanden und Modell passt."
        return 0
      fi
    fi
    if echo "$health_json" | jq -e '.checks.manifest_model.match == false' >/dev/null 2>&1; then
      model_match_state="false"
      print_warn "Remote-Modell weicht von stacks.yaml ab. Führe Setup neu aus..."
    fi
  
    # Prüfe ob Manifest existiert (neuer Weg)
    if python3 "${VAST_PY}" remote-file-exists "$stack" "/etc/stack_manifest.json" --json 2>/dev/null | jq -e '.exists == true' >/dev/null; then
      if [[ "$model_match_state" != "false" && "${image_assets_stale}" != "true" ]]; then
        print_ok "Setup bereits vorhanden (Manifest existiert)."
        return 0
      fi
    fi

    # Fallback: Prüfe /onstart.sh (alter Weg)
    if python3 "${VAST_PY}" remote-file-exists "$stack" "/onstart.sh" --json 2>/dev/null | jq -e '.exists == true' >/dev/null; then
      if [[ "$model_match_state" != "false" && "${image_assets_stale}" != "true" ]]; then
        print_ok "Setup bereits vorhanden (/onstart.sh existiert)."
        return 0
      fi
    fi
  fi
  
  print_info "Setup nicht vollständig. Führe remote setup aus..."
  if [[ ! -f "${REMOTE_SETUP}" ]]; then
    print_err "Remote-Setup-Skript ${REMOTE_SETUP} nicht gefunden."
    return 1
  fi
  
  local hf_token
  hf_token="$(resolve_hf_token)"
  
  # Hole Stack-Konfiguration
  local stack_model stack_model_file_hint stack_template service_port stack_loras_json stack_loras_json_quoted
  local remote_image_app=""
  stack_model=$(python3 -c "import yaml; c=yaml.safe_load(open('${STACKS_YAML}')); print(c.get('stacks', {}).get('${stack}', {}).get('default_model', ''))")
  stack_model_file_hint=$(python3 -c "import yaml; c=yaml.safe_load(open('${STACKS_YAML}')); print(c.get('stacks', {}).get('${stack}', {}).get('model_file_hint', ''))")
  stack_template=$(python3 -c "import yaml; c=yaml.safe_load(open('${STACKS_YAML}')); print(c.get('stacks', {}).get('${stack}', {}).get('vast_template', ''))")
  service_port=$(python3 -c "import yaml; c=yaml.safe_load(open('${STACKS_YAML}')); print(c.get('stacks', {}).get('${stack}', {}).get('service_port', ''))")
  stack_loras_json=$(python3 -c "import json,yaml; c=yaml.safe_load(open('${STACKS_YAML}')); print(json.dumps(c.get('stacks', {}).get('${stack}', {}).get('loras', [])))")
  stack_loras_json_quoted=$(python3 -c "import shlex,sys; print(shlex.quote(sys.argv[1]))" "${stack_loras_json}")

  print_info "Lade ${REMOTE_SETUP} hoch..."
  if ! scp -o StrictHostKeyChecking=no -o ConnectTimeout=20 -P "${INSTANCE_PORT}" \
    "${REMOTE_SETUP}" root@"${INSTANCE_IP}":~/setup_remote.sh; then
    print_err "Upload fehlgeschlagen."
    return 1
  fi
  if [[ "$stack" == "image" && -f "${IMAGE_APP_SOURCE}" ]]; then
    print_info "Lade ${IMAGE_APP_SOURCE##*/} hoch..."
    if ! scp -o StrictHostKeyChecking=no -o ConnectTimeout=20 -P "${INSTANCE_PORT}" \
      "${IMAGE_APP_SOURCE}" root@"${INSTANCE_IP}":~/image_app.py; then
      print_err "Upload der Image-App fehlgeschlagen."
      return 1
    fi
    remote_image_app="/root/image_app.py"
  fi
  
  print_info "Führe remote setup aus (Model: ${stack_model:-default})..."
  local setup_rc=0
  print_info "Live-Log vom Remote-Setup:"
  ssh -o StrictHostKeyChecking=no -o ConnectTimeout=20 -o ServerAliveInterval=30 \
    -p "${INSTANCE_PORT}" root@"${INSTANCE_IP}" \
    "chmod +x ~/setup_remote.sh && STACK_TYPE='${stack}' STACK_MODEL='${stack_model}' STACK_MODEL_FILE_HINT='${stack_model_file_hint}' STACK_TEMPLATE='${stack_template}' SERVICE_PORT='${service_port}' PULL_MODEL=1 FORCE_MODEL_REINSTALL='${FORCE_MODEL_REINSTALL:-0}' HF_TOKEN='${hf_token}' IMAGE_APP_SOURCE='${remote_image_app}' IMAGE_LORAS_JSON=${stack_loras_json_quoted} bash ~/setup_remote.sh" || setup_rc=$?
  if (( setup_rc != 0 )); then
    print_err "Remote setup fehlgeschlagen."
    return 1
  fi
  print_ok "Setup abgeschlossen."
  return 0
}

ensure_stack_started() {
  local stack="$1"
  local log_tail_pid=""
  local force_restart="${FORCE_STACK_RESTART:-0}"
  require_state "$stack"
  ensure_instance_running "$stack"
  wait_for_ssh "$stack" 120 5
  
  # Hole Service-Port aus stacks.yaml
  local port
  port=$(python3 -c "import yaml; c=yaml.safe_load(open('${STACKS_YAML}')); print(c.get('stacks', {}).get('${stack}', {}).get('service_port', ''))")
  
  print_info "Starte Dienst für ${stack} (Port: ${port})..."
  
  # Prüfe ob Dienst bereits läuft
  if [[ "${force_restart}" != "1" ]] && python3 "${VAST_PY}" remote-port-open "$stack" "$port" --json 2>/dev/null | jq -e '.port_open == true' >/dev/null; then
    print_ok "Dienst bereits auf Port ${port} erreichbar."
    return 0
  fi

  if [[ "${force_restart}" == "1" ]]; then
    print_warn "Erzwinge Neustart des Dienstes auf Port ${port}..."
    ssh -o StrictHostKeyChecking=no -o ConnectTimeout=15 -p "${INSTANCE_PORT}" root@"${INSTANCE_IP}" \
      "pids=\$(lsof -ti tcp:${port} 2>/dev/null || true); if [[ -n \"\$pids\" ]]; then kill \$pids >/dev/null 2>&1 || true; sleep 2; kill -9 \$pids >/dev/null 2>&1 || true; fi" \
      >/dev/null 2>&1 || true
  fi
  
  # Start via /onstart.sh
  print_info "Führe /onstart.sh aus..."
  start_remote_log_stream "$stack"
  log_tail_pid="${REMOTE_LOG_TAIL_PID:-}"
  if ! ssh -o StrictHostKeyChecking=no -o ConnectTimeout=15 -p "${INSTANCE_PORT}" root@"${INSTANCE_IP}" "bash /onstart.sh"; then
    stop_remote_log_stream "$log_tail_pid"
    print_remote_log_snapshot "$stack"
    print_warn "/onstart.sh konnte nicht ausgeführt werden."
    return 1
  fi
  
  # Warte auf Port
  print_info "Warte auf Dienst (Port ${port})..."
  local max=60 interval=3 i=0
  for ((i=0; i<max; i++)); do
    if python3 "${VAST_PY}" remote-port-open "$stack" "$port" --json 2>/dev/null | jq -e '.port_open == true' >/dev/null; then
      stop_remote_log_stream "$log_tail_pid"
      print_ok "Dienst auf Port ${port} erreichbar."
      return 0
    fi
    if (( i > 0 && i % 5 == 0 )); then
      print_info "Noch nicht bereit (${stack}, $((i*interval))s gewartet)..."
    fi
    sleep "$interval"
  done
  stop_remote_log_stream "$log_tail_pid"
  print_remote_log_snapshot "$stack"
  print_err "Dienst nach $((max*interval))s nicht erreichbar."
  return 1
}

repair_stack() {
  local stack="$1"
  print_info "Repariere Stack ${stack}..."
  if ensure_stack_setup "$stack" && ensure_stack_started "$stack"; then
    print_ok "Reparatur erfolgreich."
    return 0
  else
    print_err "Reparatur fehlgeschlagen."
    return 1
  fi
}

pick_local_port() {
  local preferred="$1"
  local port="$preferred"
  local max_offset=20
  
  is_port_free() {
    if command -v ss >/dev/null 2>&1; then
      ! ss -tuln | grep -q ":${1} "
    elif command -v netstat >/dev/null 2>&1; then
      ! netstat -tuln 2>/dev/null | grep -q ":${1} "
    else
      python3 -c "import socket; s=socket.socket(); s.bind(('', ${1})); s.close()" 2>/dev/null
    fi
  }
  
  for offset in $(seq 0 "$max_offset"); do
    port=$((preferred + offset))
    if is_port_free "$port"; then
      echo "$port"
      return 0
    fi
  done
  
  for port in $(seq 1025 65535); do
    if is_port_free "$port"; then
      echo "$port"
      return 0
    fi
  done
  echo "$preferred"
}

# ---------- Commands ----------

cmd_rent() {
  local stack="${1:?Stack fehlt}"
  local force="${2:-}"
  require_valid_stack "$stack"

  if [[ ! -f "${VAST_KEY_FILE}" ]]; then
    print_err "Vast.ai API-Key fehlt: ${VAST_KEY_FILE}"
    print_info "Erstelle Key-Datei mit:"
    echo "  echo 'DEIN_API_KEY' > ${VAST_KEY_FILE}"
    echo "  chmod 600 ${VAST_KEY_FILE}"
    return 1
  fi

  # Nur blockieren wenn State existiert UND kein --force Flag
  if load_state "$stack" 2>/dev/null && [[ "$force" != "--force" ]]; then
    print_warn "State existiert bereits für ${stack}: ${INSTANCE_ID} (${INSTANCE_IP}:${INSTANCE_PORT})"
    echo "  Nutze: ./manage_v7_fixed.sh resume ${stack}  (um Instanz zu starten)"
    echo "  Oder:  ./manage_v7_fixed.sh delete ${stack}  (um State zu löschen)"
    echo "  Oder:  ./manage_v7_fixed.sh rent ${stack} --force  (um neu zu mieten)"
    return 0
  elif load_state "$stack" 2>/dev/null && [[ "$force" == "--force" ]]; then
    print_info "--force: Miete neue Instanz trotz vorhandenem State..."
  fi
  
  # Delegate to vast.py rent
  print_info "Miete neue Instanz für ${stack}..."
  if python3 "${VAST_PY}" rent "$stack" --yes; then
    print_ok "Instanz erfolgreich gemietet."
    return 0
  else
    print_err "Miete fehlgeschlagen."
    return 1
  fi
}

cmd_use() {
  local stack="${1:?Stack fehlt}"
  local selector="${2:?Selector fehlt (id|label|gpu|last)}"
  require_valid_stack "$stack"
  
  print_info "Resolve Instanz für Selector: ${selector}"
  local iid
  if [[ "$selector" =~ ^[0-9]+$ ]]; then
    iid="$selector"
  else
    local instances_json
    instances_json="$(python3 "${VAST_PY}" list --json 2>/dev/null || echo '[]')"
    if [[ "$selector" == "last" ]]; then
      iid="$(echo "$instances_json" | jq -r '.[0].id // empty')"
    else
      iid="$(echo "$instances_json" | jq -r --arg sel "$selector" '
        .[] | select((.label | ascii_downcase | contains($sel)) or (.id | tostring | contains($sel)) or ((.gpu_name // "") | ascii_downcase | contains($sel))) | .id
      ' | head -1)"
    fi
  fi
  
  if [[ -z "$iid" ]]; then
    print_err "Keine Instanz gefunden für Selector: ${selector}"
    return 1
  fi
  
  print_info "Hole Details für Instanz ${iid}..."
  local info ip port
  info="$(vastai show instance "$iid" --raw 2>/dev/null || true)"
  if [[ -z "$info" || "$info" == "null" ]]; then
    print_err "Konnte Instanz-Daten nicht abrufen."
    return 1
  fi
  ip="$(echo "$info" | jq -r '.ssh_host // .public_ipaddr // empty')"
  port="$(echo "$info" | jq -r '.ssh_port // empty')"
  if [[ -z "$ip" || -z "$port" ]]; then
    print_err "Instanz hat keine SSH-Details (noch nicht bereit?)."
    return 1
  fi
  
  save_state "$stack" "$iid" "$ip" "$port"
  print_ok "Stack ${stack} -> Instanz ${iid} (${ip}:${port})"
  return 0
}

cmd_resume() {
  local stack="${1:?Stack fehlt}"
  require_state "$stack"
  ensure_instance_running "$stack"
  
  print_info "Aktualisiere State..."
  local info ip port
  info="$(vastai show instance "${INSTANCE_ID}" --raw 2>/dev/null || true)"
  if [[ -n "$info" && "$info" != "null" ]]; then
    ip="$(echo "$info" | jq -r '.ssh_host // .public_ipaddr // empty')"
    port="$(echo "$info" | jq -r '.ssh_port // empty')"
    if [[ -n "$ip" && -n "$port" ]]; then
      save_state "$stack" "${INSTANCE_ID}" "$ip" "$port"
    fi
  fi
  print_ok "Instanz ${INSTANCE_ID} ist running."
  return 0
}

cmd_setup() {
  local stack="${1:?Stack fehlt}"
  require_state "$stack"
  ensure_stack_setup "$stack"
  print_ok "Setup für ${stack} abgeschlossen."
}

cmd_start() {
  local stack="${1:?Stack fehlt}"
  require_state "$stack"
  ensure_stack_started "$stack"
  print_ok "Dienst für ${stack} gestartet."
}

cmd_repair() {
  local stack="${1:?Stack fehlt}"
  require_state "$stack"
  repair_stack "$stack"
}

cmd_login() {
  local stack="${1:?Stack fehlt}"
  require_state "$stack"

  if ! ensure_instance_running "$stack"; then
    print_err "Instanz für ${stack} konnte nicht gestartet werden."
    return 1
  fi
  if ! wait_for_ssh "$stack" 120 5; then
    print_err "SSH für ${stack} nicht erreichbar."
    return 1
  fi
  
  # Hole Ports aus stacks.yaml
  local local_port service_port api_remote_port api_tunnel_port
  local_port=$(python3 -c "import yaml; c=yaml.safe_load(open('${STACKS_YAML}')); print(c.get('stacks', {}).get('${stack}', {}).get('local_port', c.get('stacks', {}).get('${stack}', {}).get('service_port', '')))")
  service_port=$(python3 -c "import yaml; c=yaml.safe_load(open('${STACKS_YAML}')); print(c.get('stacks', {}).get('${stack}', {}).get('service_port', ''))")
  api_remote_port=$(python3 -c "import yaml; c=yaml.safe_load(open('${STACKS_YAML}')); s=c.get('stacks', {}).get('${stack}', {}); v=s.get('api_remote_port', s.get('ollama_remote_port')); print(v if v else '')")
  api_tunnel_port=$(python3 -c "import yaml; c=yaml.safe_load(open('${STACKS_YAML}')); s=c.get('stacks', {}).get('${stack}', {}); v=s.get('api_tunnel_port', s.get('ollama_tunnel_port')); print(v if v else '')")

  if [[ -z "$local_port" || -z "$service_port" ]]; then
    print_err "Konnte Ports nicht aus stacks.yaml lesen."
    return 1
  fi

  print_info "Kein Readiness-Check: Tunnel wird direkt aufgebaut."
  print_info "Öffne Tunnel für ${stack} auf lokalem Port ${local_port}..."

  local ssh_opts="-N -o StrictHostKeyChecking=no -o ServerAliveInterval=30 -p ${INSTANCE_PORT}"
  local tunnel_cmd="ssh ${ssh_opts} -L ${local_port}:127.0.0.1:${service_port} root@${INSTANCE_IP}"

  if [[ -n "$api_remote_port" && -n "$api_tunnel_port" ]]; then
    tunnel_cmd="ssh ${ssh_opts} -L ${local_port}:127.0.0.1:${service_port} -L ${api_tunnel_port}:127.0.0.1:${api_remote_port} root@${INSTANCE_IP}"
  fi

  exec bash -c "$tunnel_cmd"
}

cmd_login_ssh() {
  local stack="${1:?Stack fehlt}"
  require_state "$stack"

  if ! ensure_instance_running "$stack"; then
    print_err "Instanz für ${stack} konnte nicht gestartet werden."
    return 1
  fi
  if ! wait_for_ssh "$stack" 120 5; then
    print_err "SSH für ${stack} nicht erreichbar."
    return 1
  fi

  print_info "Öffne SSH-Shell für ${stack}..."
  exec ssh -t \
    -o StrictHostKeyChecking=no \
    -o ServerAliveInterval=30 \
    -p "${INSTANCE_PORT}" \
    "root@${INSTANCE_IP}"
}

cmd_tunnel() {
  local stack="${1:?Stack fehlt}"
  require_state "$stack"

  local local_port service_port api_remote_port api_tunnel_port
  local_port=$(python3 -c "import yaml; c=yaml.safe_load(open('${STACKS_YAML}')); print(c.get('stacks', {}).get('${stack}', {}).get('local_port', c.get('stacks', {}).get('${stack}', {}).get('service_port', '')))")
  service_port=$(python3 -c "import yaml; c=yaml.safe_load(open('${STACKS_YAML}')); print(c.get('stacks', {}).get('${stack}', {}).get('service_port', ''))")
  api_remote_port=$(python3 -c "import yaml; c=yaml.safe_load(open('${STACKS_YAML}')); s=c.get('stacks', {}).get('${stack}', {}); v=s.get('api_remote_port', s.get('ollama_remote_port')); print(v if v else '')")
  api_tunnel_port=$(python3 -c "import yaml; c=yaml.safe_load(open('${STACKS_YAML}')); s=c.get('stacks', {}).get('${stack}', {}); v=s.get('api_tunnel_port', s.get('ollama_tunnel_port')); print(v if v else '')")

  echo "Tunnel-Befehl für ${stack}:"
  if [[ -n "$api_remote_port" && -n "$api_tunnel_port" ]]; then
    echo "  ssh -N -L ${local_port}:127.0.0.1:${service_port} -L ${api_tunnel_port}:127.0.0.1:${api_remote_port} -p ${INSTANCE_PORT} root@${INSTANCE_IP}"
  else
    echo "  ssh -N -L ${local_port}:127.0.0.1:${service_port} -p ${INSTANCE_PORT} root@${INSTANCE_IP}"
  fi
  
  if [[ -t 0 ]]; then
    read -r -p "Tunnel jetzt starten? (y/N) " ans
    if [[ "${ans:-}" =~ ^[Yy]$ ]]; then
      cmd_login "$stack"
    fi
  fi
}

cmd_delete() {
  local stack="${1:?Stack fehlt}"
  local mode="${2:-}"
  if load_state "$stack" 2>/dev/null; then
    local iid="${INSTANCE_ID}"
    if [[ "$mode" == "--remote" ]]; then
      print_info "Zerstöre Remote-Instanz ${iid}..."
      if vastai destroy instance "$iid" >/dev/null 2>&1; then
        print_ok "Remote-Instanz ${iid} zerstört."
      else
        print_warn "Remote-Zerstörung fehlgeschlagen (vielleicht bereits gelöscht)."
      fi
    fi
    clear_state "$stack"
  else
    print_warn "Kein State für ${stack} gefunden."
  fi
  print_ok "Lokaler State für ${stack} bereinigt."
}

cmd_status() {
  local stack="${1:-}"
  if [[ -n "$stack" ]]; then
    require_valid_stack "$stack"
    if load_state "$stack" 2>/dev/null; then
      echo "Stack: ${stack}"
      echo "  Instanz-ID: ${INSTANCE_ID}"
      echo "  IP:Port:    ${INSTANCE_IP}:${INSTANCE_PORT}"
      local health_json
      health_json="$(stack_health "$stack")"
      echo "  Gesund:     $(echo "$health_json" | jq -r '.ready // false')"
      echo "  SSH:        $(echo "$health_json" | jq -r '.ssh_reachable // false')"
      echo "  Manifest:   $(echo "$health_json" | jq -r '.manifest_exists // false')"
      echo "  Fehlend:    $(echo "$health_json" | jq -r '.missing // [] | join(", ")')"
    else
      echo "Stack: ${stack} – keine State-Datei"
    fi
  else
    vastai show instances 2>/dev/null || true
  fi
}

cmd_health() {
  local stack="${1:?Stack fehlt}"
  require_valid_stack "$stack"
  stack_health "$stack" | jq .
}

cmd_ensure_ready() {
  local stack="${1:?Stack fehlt}"
  require_valid_stack "$stack"
  print_info "Stelle sicher, dass ${stack} bereit ist..."
  
  if ! load_state "$stack" 2>/dev/null; then
    print_warn "Kein State für ${stack}. Miete neue Instanz..."
    cmd_rent "$stack" || return 1
    load_state "$stack" || die "State konnte nicht geladen werden."
  fi
  
  ensure_instance_running "$stack" || return 1
  wait_for_ssh "$stack" 300 5 || return 1
  ensure_stack_setup "$stack" || return 1
  ensure_stack_started "$stack" || return 1
  
  if is_stack_ready "$stack"; then
    print_ok "Stack ${stack} ist bereit."
    return 0
  else
    print_err "Stack ${stack} ist nach allen Schritten nicht bereit."
    return 1
  fi
}

cmd_help() {
  cat <<HELP
Verwendung:
  ./manage_v7_fixed.sh <befehl> <stack> [argumente]

Verfügbare Stacks: $(get_available_stacks)

Befehle:
  rent <stack> [--force]         Neue Instanz mieten
  use <stack> <selector>         Bestehende Instanz adoptieren (id|label|gpu|last)
  delete <stack> [--remote]      State löschen (optional remote zerstören)
  resume <stack>                 Instanz starten und State aktualisieren
  setup <stack>                  Remote-Setup durchführen (idempotent)
  start <stack>                  Dienst starten (idempotent)
  repair <stack>                 Stack reparieren (Setup + Start)
  login <stack>                  SSH-Tunnel öffnen (mit Port-Auswahl)
  login_ssh <stack>              Interaktive Shell auf Remote-Instanz öffnen
  tunnel <stack>                 Tunnel-Befehl anzeigen
  status [stack]                 Status anzeigen (alle oder ein Stack)
  health <stack>                 Detaillierten Health-Check anzeigen (JSON)
  ensure-ready <stack>           Stack komplett vorbereiten (Rent/Use → Ready)

Beispiele:
  ./manage_v7_fixed.sh rent text
  ./manage_v7_fixed.sh use video last
  ./manage_v7_fixed.sh ensure-ready text
  ./manage_v7_fixed.sh login image
  ./manage_v7_fixed.sh login_ssh image
HELP
}

# ---------- Main ----------
main() {
  local cmd="${1:-help}"
  shift 2>/dev/null || true
  
  case "$cmd" in
    rent)          cmd_rent "$@" ;;
    use)           cmd_use "$@" ;;
    delete)        cmd_delete "$@" ;;
    resume)        cmd_resume "$@" ;;
    setup)         cmd_setup "$@" ;;
    start)         cmd_start "$@" ;;
    repair)        cmd_repair "$@" ;;
    login)         cmd_login "$@" ;;
    login_ssh)     cmd_login_ssh "$@" ;;
    tunnel)        cmd_tunnel "$@" ;;
    status)        cmd_status "$@" ;;
    health)        cmd_health "$@" ;;
    ensure-ready)  cmd_ensure_ready "$@" ;;
    help|*)        cmd_help "$@" ;;
  esac
}

main "$@"
