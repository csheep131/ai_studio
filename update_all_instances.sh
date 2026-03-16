#!/usr/bin/env bash
#
# update_all_instances.sh - Aktualisiert ALLE gemieteten Vast.ai-Instanzen
# mit dem neuesten setup_remote_v3.sh
#
# Verwendung:
#   ./update_all_instances.sh              # Alle Instanzen updaten
#   ./update_all_instances.sh --dry-run    # Nur anzeigen, nicht updaten
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VAST_PY="${SCRIPT_DIR}/vast.py"
STACKS_YAML="${SCRIPT_DIR}/stacks.yaml"
REMOTE_SETUP="${SCRIPT_DIR}/setup_remote_v3.sh"
HF_TOKEN_FILE="${SCRIPT_DIR}/.hf_token"
ENV_FILE="${SCRIPT_DIR}/.env"
STATE_DIR="${SCRIPT_DIR}"

DRY_RUN=0
FORCE_REINSTALL=0

# Farben
if [[ -t 1 ]]; then
  RED='\033[0;31m'
  GREEN='\033[0;32m'
  YELLOW='\033[1;33m'
  BLUE='\033[0;34m'
  BOLD='\033[1m'
  NC='\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; BLUE=''; BOLD=''; NC=''
fi

print_info()  { echo -e "${BLUE}▶${NC} $*"; }
print_ok()    { echo -e "${GREEN}✓${NC} $*"; }
print_warn()  { echo -e "${YELLOW}⚠${NC} $*"; }
print_err()   { echo -e "${RED}✗${NC} $*"; }
print_header() { echo -e "${BOLD}═══ $* ═══${NC}"; }

die() { print_err "$*"; exit 1; }

# Parse arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --force)
      FORCE_REINSTALL=1
      shift
      ;;
    -h|--help)
      echo "Verwendung: $0 [--dry-run] [--force]"
      echo "  --dry-run  Zeige nur Instanzen, ohne Update"
      echo "  --force    Erzwinge Setup auch bei aktuellen Instanzen"
      exit 0
      ;;
    *)
      die "Unbekanntes Argument: $1"
      ;;
  esac
done

# Prüfen ob required files existieren
need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Fehlender Befehl: $1"
}

need_cmd python3
need_cmd jq
need_cmd ssh
need_cmd scp

if [[ ! -f "${REMOTE_SETUP}" ]]; then
  die "Remote-Setup-Skript nicht gefunden: ${REMOTE_SETUP}"
fi

# HF Token laden
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

# SSH Key finden
find_ssh_key() {
  local key=""
  # Priorisierte Liste von SSH-Keys
  for keyfile in ~/.ssh/id_ed25519 ~/.ssh/id_rsa ~/.ssh/id_ed25519_new; do
    if [[ -f "${keyfile}" ]]; then
      key="${keyfile}"
      break
    fi
  done
  echo "${key}"
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
HF_TOKEN_VALUE="$(resolve_hf_token)"
SSH_KEY_FILE="$(find_ssh_key)"

print_header "Vast.ai Instanzen Update"
echo ""

# Alle State-Dateien finden und mit API-Status abgleichen
print_info "Suche nach gemieteten Instanzen (State-Dateien)..."
print_info "Hole aktuellen Status von Vast.ai API..."

# API-Daten holen
INSTANCES_JSON=$(python3 "${VAST_PY}" list --json 2>/dev/null) || die "Konnte Instanzen nicht von API abrufen"

declare -a INSTANCES=()
declare -A API_STATUS_MAP=()

# API-Status in Map speichern
while IFS= read -r line; do
  api_id=$(echo "${line}" | jq -r '.id // empty')
  api_status=$(echo "${line}" | jq -r '.status // "unknown"')
  [[ -n "${api_id}" ]] && API_STATUS_MAP["${api_id}"]="${api_status}"
done < <(echo "${INSTANCES_JSON}" | jq -c '.[]' 2>/dev/null)

for state_file in "${STATE_DIR}"/.vast_instance_*; do
  [[ -f "${state_file}" ]] || continue
  
  # State-Datei auslesen
  unset INSTANCE_ID INSTANCE_IP INSTANCE_PORT STACK INSTANCE_STATUS
  source "${state_file}" 2>/dev/null || continue
  
  # Alle benötigten Felder müssen vorhanden sein
  [[ -n "${INSTANCE_ID:-}" && -n "${INSTANCE_IP:-}" && -n "${INSTANCE_PORT:-}" && -n "${STACK:-}" ]] || continue
  
  # Aktualischen Status von API verwenden
  actual_status="${API_STATUS_MAP[${INSTANCE_ID}]:-not_found}"
  
  INSTANCES+=("${INSTANCE_ID}|${STACK}|${INSTANCE_IP}|${INSTANCE_PORT}|${actual_status}")
done

if [[ ${#INSTANCES[@]} -eq 0 ]]; then
  print_warn "Keine Instanzen gefunden."
  exit 0
fi

print_ok "Gefundene Instanzen: ${#INSTANCES[@]}"
echo ""

# Tabelle anzeigen
echo "┌──────────┬──────────────────┬───────────────────┬──────────┬────────────┐"
echo "│ ID       │ Stack            │ SSH Host          │ Port     │ Status     │"
echo "├──────────┼──────────────────┼───────────────────┼──────────┼────────────┤"

for inst_entry in "${INSTANCES[@]}"; do
  IFS='|' read -r id stack ip port status <<< "${inst_entry}"
  printf "│ %-9s│ %-17s│ %-18s│ %-9s│ %-11s│\n" \
    "${id:0:9}" "${stack:0:17}" "${ip:0:18}" "${port:0:9}" "${status:0:11}"
done

echo "└──────────┴──────────────────┴───────────────────┴──────────┴────────────┘"
echo ""

if [[ ${DRY_RUN} -eq 1 ]]; then
  print_info "Dry-Run: Keine Updates durchgeführt."
  exit 0
fi

# Bestätigung
if [[ -t 0 ]]; then
  read -p "Diese ${#INSTANCES[@]} Instanz(en) updaten? [j/N] " -n 1 -r
  echo ""
  if [[ ! $REPLY =~ ^[Jj]$ ]]; then
    print_info "Abgebrochen."
    exit 0
  fi
fi

# Update für jede Instanz
SUCCESS_COUNT=0
FAIL_COUNT=0

for inst_entry in "${INSTANCES[@]}"; do
  IFS='|' read -r id stack ip port status <<< "${inst_entry}"
  
  # Nur laufende Instanzen updaten
  if [[ "${status}" != "running" ]]; then
    print_warn "Instanz ${id} (${stack}) hat Status '${status}' - wird übersprungen"
    continue
  fi
  
  ssh_user="root"
  ssh_target="${ssh_user}@${ip}"
  STACK_TYPE="${stack}"
  
  print_header "Update Instanz ${id} (${stack})"
  
  # Stack-Typ ist bereits aus State-Datei bekannt
  print_info "Stack: ${STACK_TYPE}"
  
  # Setup neu ausführen
  print_info "Lade setup_remote_v3.sh hoch..."
  
  # SSH Optionen mit Key-Datei
  ssh_key_opts=""
  if [[ -n "${SSH_KEY_FILE}" ]]; then
    ssh_key_opts="-i ${SSH_KEY_FILE}"
  fi
  ssh_opts="-o StrictHostKeyChecking=no -o ConnectTimeout=30 -o ServerAliveInterval=30 -o ServerAliveCountMax=3 ${ssh_key_opts}"
  
  # Erst testen ob SSH funktioniert
  if ! ssh ${ssh_opts} -p "${port}" "${ssh_target}" "echo 'SSH OK'" >/dev/null 2>&1; then
    print_err "SSH-Verbindung fehlgeschlagen!"
    print_warn "Teste SSH manuell:"
    print_warn "  ssh ${ssh_opts} -p ${port} ${ssh_target}"
    ((FAIL_COUNT++)) || true
    continue
  fi
  
  # Prüfe verfügbaren Speicherplatz
  disk_info=$(ssh ${ssh_opts} -p "${port}" "${ssh_target}" "df -h / | tail -1" 2>/dev/null || echo "")
  if [[ -n "${disk_info}" ]]; then
    disk_used=$(echo "${disk_info}" | awk '{print $5}' | tr -d '%')
    if [[ "${disk_used:-0}" -gt 90 ]]; then
      print_warn "Speicherplatz kritisch: ${disk_used}% belegt"
      print_info "Versuche aufzuräumen..."
      ssh ${ssh_opts} -p "${port}" "${ssh_target}" "rm -rf /tmp/* ~/setup_remote.sh /root/setup_remote.sh 2>/dev/null || true" 2>/dev/null || true
    fi
  fi
  
  upload_output=$(scp ${ssh_opts} -P "${port}" \
    "${REMOTE_SETUP}" "${ssh_target}":~/setup_remote.sh 2>&1 || true)
  
  if ! echo "${upload_output}" | grep -q "100%"; then
    if echo "${upload_output}" | grep -qi "permission denied\|publickey\|authentication"; then
      print_err "SSH-Authentifizierung fehlgeschlagen - SSH-Key ungültig für diese Instanz!"
      print_err "Tipp: Instanz wurde evtl. neu erstellt und hat neuen SSH-Key."
    elif echo "${upload_output}" | grep -qi "write.*failure\|no space\|disk quota"; then
      print_err "Upload fehlgeschlagen - kein Speicherplatz auf der Instanz!"
      print_err "Tipp: SSH manuell verbinden und Platz freigeben:"
      print_err "  ssh ${ssh_opts} -p ${port} ${ssh_target}"
      print_err "  rm -rf /opt/models/*/model/*  # Oder andere große Dateien"
    else
      print_err "Upload fehlgeschlagen."
    fi
    print_warn "SCP Output: ${upload_output}"
    ((FAIL_COUNT++)) || true
    continue
  fi
  
  # Stack-Konfiguration holen
  stack_model=$(python3 -c "import yaml; c=yaml.safe_load(open('${STACKS_YAML}')); print(c.get('stacks', {}).get('${STACK_TYPE}', {}).get('default_model', ''))" 2>/dev/null || echo "")
  stack_template=$(python3 -c "import yaml; c=yaml.safe_load(open('${STACKS_YAML}')); print(c.get('stacks', {}).get('${STACK_TYPE}', {}).get('vast_template', ''))" 2>/dev/null || echo "")
  service_port=$(python3 -c "import yaml; c=yaml.safe_load(open('${STACKS_YAML}')); print(c.get('stacks', {}).get('${STACK_TYPE}', {}).get('service_port', ''))" 2>/dev/null || echo "")
  
  # HF Token für diese Instanz
  inst_hf_token="${HF_TOKEN_VALUE}"
  
  print_info "Starte Setup für Stack: ${STACK_TYPE}"
  print_info "Modell: ${stack_model:-default}"

  # Setup ausführen mit reduziertem Output
  setup_output=$(ssh ${ssh_opts} -p "${port}" "${ssh_target}" \
    "chmod +x ~/setup_remote.sh && \
     STACK_TYPE='${STACK_TYPE}' \
     STACK_MODEL='${stack_model}' \
     STACK_TEMPLATE='${stack_template}' \
     SERVICE_PORT='${service_port}' \
     PULL_MODEL=1 \
     FORCE_MODEL_REINSTALL='${FORCE_REINSTALL}' \
     HF_TOKEN='${inst_hf_token}' \
     bash ~/setup_remote.sh" 2>&1 || echo "EXIT_CODE:$?")
  
  # Prüfe auf Erfolg
  if echo "${setup_output}" | grep -q "✓ Stack Ready"; then
    print_ok "Setup erfolgreich!"
    ((SUCCESS_COUNT++)) || true
  elif echo "${setup_output}" | grep -q "already"; then
    print_ok "Setup bereits aktuell (übersprungen)."
    ((SUCCESS_COUNT++)) || true
  else
    print_warn "Setup Output:"
    echo "${setup_output}" | tail -20
    if echo "${setup_output}" | grep -q "EXIT_CODE:"; then
      print_err "Setup mit Fehler beendet."
      ((FAIL_COUNT++)) || true
    else
      ((SUCCESS_COUNT++)) || true
    fi
  fi
  
  echo ""
done

# Zusammenfassung
print_header "Update Zusammenfassung"
print_ok "Erfolgreich: ${SUCCESS_COUNT}"
if [[ ${FAIL_COUNT} -gt 0 ]]; then
  print_err "Fehlgeschlagen: ${FAIL_COUNT}"
fi

echo ""
print_info "Alle Updates abgeschlossen."
