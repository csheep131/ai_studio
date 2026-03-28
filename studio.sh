#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANAGE_SCRIPT="${SCRIPT_DIR}/manage_v7_fixed.sh"
WORKFLOW_SCRIPT="${SCRIPT_DIR}/video_script_full_workflow.sh"
INSTALL_SCRIPT="${SCRIPT_DIR}/install_v7.sh"
VAST_PY="${SCRIPT_DIR}/vast.py"
STACKS_YAML="${SCRIPT_DIR}/stacks.yaml"

# ---------- UI ----------
if [[ -t 1 ]]; then
  RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'; BLUE=$'\033[0;34m'
  MAGENTA=$'\033[0;35m'; CYAN=$'\033[0;36m'; WHITE=$'\033[1;37m'; BOLD=$'\033[1m'
  DIM=$'\033[2m'; NC=$'\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; BLUE=''; MAGENTA=''; CYAN=''; WHITE=''; BOLD=''; DIM=''; NC=''
fi

say()   { echo -e "${GREEN}$*${NC}"; }
info()  { echo -e "${CYAN}$*${NC}"; }
warn()  { echo -e "${YELLOW}$*${NC}" >&2; }
err()   { echo -e "${RED}$*${NC}" >&2; }
die()   { err "✗ $*"; exit 1; }
need()  { command -v "$1" >/dev/null 2>&1 || die "Fehlender Befehl: $1"; }

UI_UTF8=false
if [[ "${AI_STUDIO_UTF8:-0}" == "1" ]]; then
  UI_UTF8=true
fi

if [[ "$UI_UTF8" == true ]]; then
  BOX_TL='┌'; BOX_TR='┐'; BOX_BL='└'; BOX_BR='┘'; BOX_H='─'; BOX_V='│'; BOX_L='├'; BOX_R='┤'
  STATUS_GOOD='●'; STATUS_WARN='●'; STATUS_BAD='●'; ICON_OK='✓'; ICON_BAD='✗'
  SPINNER=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
else
  BOX_TL='+'; BOX_TR='+'; BOX_BL='+'; BOX_BR='+'; BOX_H='-'; BOX_V='|'; BOX_L='+'; BOX_R='+'
  STATUS_GOOD='o'; STATUS_WARN='o'; STATUS_BAD='x'; ICON_OK='OK'; ICON_BAD='x'
  SPINNER=('|' '/' '-' '\\')
fi

# ========== BOX ENGINE ==========
# Dynamische Terminalbreite
TERM_WIDTH=$(tput cols 2>/dev/null || echo 80)
BOX_WIDTH=$(( TERM_WIDTH > 100 ? 100 : TERM_WIDTH - 2 ))
(( BOX_WIDTH < 60 )) && BOX_WIDTH=60

# ANSI-Codes aus String entfernen für korrekte Breitenberechnung
strip_ansi() {
  sed -r 's/\x1B\[[0-9;]*[mK]//g'
}

# Sichtbare Länge eines Strings berechnen (ohne ANSI-Codes)
visible_len() {
  local s="$1"
  printf "%s" "$s" | strip_ansi | tr '\n' ' ' | awk 'END { print length($0) }'
}

# Zeichen wiederholen
repeat_char() {
  local char="$1"
  local count="$2"
  printf "%*s" "$count" '' | tr ' ' "$char"
}

# Box-Inhaltslinie mit korrektem Padding
box_line() {
  local text="$1"
  local inner_width=$(( BOX_WIDTH - 4 ))
  local len
  len=$(visible_len "$text")
  if (( len > inner_width )); then
    text="$(printf "%s" "$text" | strip_ansi | cut -c1-"${inner_width}")"
    len=$(visible_len "$text")
  fi
  local pad=$(( inner_width - len ))
  (( pad < 0 )) && pad=0
  printf "%s %b%*s %s\n" "$BOX_V" "$text" "$pad" "" "$BOX_V"
}

box_top() {
  printf "%s%s%s\n" "$BOX_TL" "$(repeat_char "$BOX_H" $(( BOX_WIDTH - 2 )))" "$BOX_TR"
}

box_sep() {
  printf "%s%s%s\n" "$BOX_L" "$(repeat_char "$BOX_H" $(( BOX_WIDTH - 2 )))" "$BOX_R"
}

box_bottom() {
  printf "%s%s%s\n" "$BOX_BL" "$(repeat_char "$BOX_H" $(( BOX_WIDTH - 2 )))" "$BOX_BR"
}

box_title() {
  local title="$1"
  box_top
  box_line " ${BOLD}${CYAN}${title}${NC}"
  box_bottom
}

# Box mit Titel und Inhalten (für Menüs)
box_menu_start() {
  local title="$1"
  box_top
  box_line " ${BOLD}${title}${NC}"
  box_sep
}

box_menu_end() {
  box_bottom
}

box_menu_item() {
  local text="$1"
  box_line "$text"
}
# ========== END BOX ENGINE ==========

# ---------- checks ----------
need bash
need awk
need grep
need python3
need jq

[[ -f "${MANAGE_SCRIPT}" ]] || die "manage_v7_fixed.sh nicht gefunden neben studio.sh"
if [[ -f "${VAST_PY}" ]]; then chmod +x "${VAST_PY}" 2>/dev/null || true; fi
[[ -x "${MANAGE_SCRIPT}" ]] || chmod +x "${MANAGE_SCRIPT}" 2>/dev/null || true
[[ -f "${WORKFLOW_SCRIPT}" ]] && chmod +x "${WORKFLOW_SCRIPT}" 2>/dev/null || true
[[ -f "${INSTALL_SCRIPT}" ]] && chmod +x "${INSTALL_SCRIPT}" 2>/dev/null || true
[[ -f "${STACKS_YAML}" ]] || die "stacks.yaml nicht gefunden"

state_file_for() { echo "${SCRIPT_DIR}/.vast_instance_${1}"; }
has_state() { [[ -f "$(state_file_for "$1")" ]]; }
read_state_field() {
  local stack="$1" key="$2"
  local sf="$(state_file_for "$stack")"
  [[ -f "$sf" ]] || return 1
  grep -oP "^${key}=\"\\K[^\"]*" "$sf" 2>/dev/null || true
}
is_manual_state_binding() {
  local stack="$1"
  local source
  source="$(read_state_field "$stack" "SSH_SOURCE")"
  [[ "$source" == "manual_bind" || "$source" == "manual_override" ]]
}

# ---------- Live API Abfrage ----------
# Holt aktuelle Instanz-Daten von Vast API statt sich auf State zu verlassen

get_live_instance_for_stack() {
  local stack="$1"
  
  # State-Datei lesen für erwartete Instanz-ID
  local sf="$(state_file_for "$stack")"
  local expected_iid=""
  if [[ -f "$sf" ]]; then
    source "$sf" >/dev/null 2>&1 || true
    expected_iid="${INSTANCE_ID:-}"
  fi
  
  # Live API Abfrage
  local instances_json
  instances_json=$(python3 "${VAST_PY}" list --json 2>/dev/null || echo '[]')

  # Wenn expected_iid bekannt, prüfe ob diese Instanz existiert
  if [[ -n "$expected_iid" ]]; then
    # Hinweis: vast.py gibt IDs als Strings zurück, daher ohne tonumber vergleichen
    local found
    found=$(echo "$instances_json" | jq -r --arg iid "$expected_iid" '.[] | select(.id == $iid) | .id' 2>/dev/null)
    if [[ -n "$found" ]]; then
      # Instanz existiert noch, gib Details zurück
      echo "$instances_json" | jq -r --arg iid "$expected_iid" '.[] | select(.id == $iid)'
      return 0
    fi
  fi

  return 1
}

refresh_all_stack_states() {
  local interactive="${1:-false}"
  
  print_step "Aktualisiere Instanz-Daten von Vast.ai API..."

  local instances_json
  instances_json=$(python3 "${VAST_PY}" list --json 2>/dev/null || echo '[]')
  
  # Prüfen ob es Instanzen gibt
  local inst_count
  inst_count=$(echo "$instances_json" | jq 'length' 2>/dev/null || echo "0")
  
  if [[ "$inst_count" -eq 0 || "$inst_count" == "null" ]]; then
    print_warn "Keine Instanzen auf Vast.ai gefunden."
    return 0
  fi

  # Bestehende Zuordnungen immer zuerst mit Live-Daten synchronisieren.
  _refresh_stack_states_auto "$instances_json"

  # Im interaktiven Modus zusätzlich optionales manuelles Binden anbieten.
  if [[ "$interactive" == "true" ]]; then
    _refresh_stack_states_interactive "$instances_json"
  fi
  
  return 0
}

_refresh_stack_states_auto() {
  local instances_json="$1"
  local stack_key
  
  # Automatisch State-Dateien aktualisieren (ohne Interaktion)
  for stack_key in $(get_available_stacks); do
    local sf="$(state_file_for "$stack_key")"
    local expected_iid=""
    if [[ -f "$sf" ]]; then
      expected_iid=$(grep -oP 'INSTANCE_ID="\K[^"]+' "$sf" 2>/dev/null || echo "")
    fi

    if [[ -n "$expected_iid" ]]; then
      # Prüfen ob Instanz noch existiert
      # Hinweis: vast.py gibt IDs als Strings zurück, daher ohne tonumber vergleichen
      local found
      found=$(echo "$instances_json" | jq -r --arg iid "$expected_iid" '.[] | select(.id == $iid) | .id' 2>/dev/null)

      if [[ -n "$found" ]]; then
        # Instanz existiert noch, aktualisiere Status aber behalte funktionierende Ports
        local inst_data
        inst_data=$(echo "$instances_json" | jq -r --arg iid "$expected_iid" '.[] | select(.id == $iid)')
        
        local api_ip api_port instance_status ssh_source
        api_port=$(echo "$inst_data" | jq -r '.ssh_port // empty')
        api_ip=$(echo "$inst_data" | jq -r '.ssh_host // .public_ip // .public_ipaddr // empty')
        instance_status=$(echo "$inst_data" | jq -r '.status // "unknown"')
        ssh_source=$(echo "$inst_data" | jq -r '.ssh_source // "auto_refresh"')

        # Behalte bestehende funktionierende Ports (API-Ports können off-by-one sein)
        local existing_ip existing_port existing_candidates existing_source
        existing_ip=$(grep -oP 'INSTANCE_IP="\K[^"]+' "$sf" 2>/dev/null || echo "")
        existing_port=$(grep -oP 'INSTANCE_PORT="\K[^"]+' "$sf" 2>/dev/null || echo "")
        existing_candidates=$(grep -oP 'INSTANCE_PORT_CANDIDATES="\K[^"]+' "$sf" 2>/dev/null || echo "")
        existing_source=$(grep -oP 'SSH_SOURCE="\K[^"]+' "$sf" 2>/dev/null || echo "")

        # Verwende existierende Ports wenn vorhanden, sonst API-Ports
        local use_ip="${existing_ip:-$api_ip}"
        local use_port="${existing_port:-$api_port}"
        local use_candidates="${existing_candidates:-$api_port}"

        if [[ -n "$use_ip" && -n "$use_port" ]]; then
          cat > "$sf" <<EOF
INSTANCE_ID="${expected_iid}"
INSTANCE_IP="${use_ip}"
INSTANCE_PORT="${use_port}"
INSTANCE_PORT_CANDIDATES="${use_candidates}"
INSTANCE_STATUS="${instance_status}"
SSH_SOURCE="${existing_source:-$ssh_source}"
STACK="${stack_key}"
EOF
          chmod 600 "$sf"
        fi
      else
        local existing_ip existing_port existing_candidates existing_source
        existing_ip=$(grep -oP 'INSTANCE_IP="\K[^"]+' "$sf" 2>/dev/null || echo "")
        existing_port=$(grep -oP 'INSTANCE_PORT="\K[^"]+' "$sf" 2>/dev/null || echo "")
        existing_candidates=$(grep -oP 'INSTANCE_PORT_CANDIDATES="\K[^"]+' "$sf" 2>/dev/null || echo "")
        existing_source=$(grep -oP 'SSH_SOURCE="\K[^"]+' "$sf" 2>/dev/null || echo "")
        cat > "$sf" <<EOF
INSTANCE_ID="${expected_iid}"
INSTANCE_IP="${existing_ip}"
INSTANCE_PORT="${existing_port}"
INSTANCE_PORT_CANDIDATES="${existing_candidates}"
INSTANCE_STATUS="not_found"
SSH_SOURCE="${existing_source}"
STACK="${stack_key}"
EOF
        chmod 600 "$sf"
      fi
    fi
  done
}

_refresh_stack_states_interactive() {
  local instances_json="$1"

  # Interaktive Auswahl anzeigen
  echo
  echo -e "${BOLD}${WHITE}┌────────────────────────────────────────────────────────────────────────────┐${NC}"
  echo -e "${BOLD}${WHITE}│${NC}  ${BOLD}VERFÜGBARE INSTANZEN AUF VAST.AI${NC}"
  echo -e "${BOLD}${WHITE}├────────────────────────────────────────────────────────────────────────────┤${NC}"
  echo -e "${BOLD}${WHITE}│${NC}  ${BOLD}Nr${NC}  ${BOLD}ID${NC}       ${BOLD}Status${NC}     ${BOLD}GPU${NC}            ${BOLD}SSH${NC}                    ${BOLD}Stack${NC}"
  echo -e "${BOLD}${WHITE}├────────────────────────────────────────────────────────────────────────────┤${NC}"

  # Instanzen mit Nummern anzeigen - Python für zuverlässige Ausgabe
  local tmpfile tmpfile_json
  tmpfile=$(mktemp)
  tmpfile_json=$(mktemp)
  
  # JSON in temporäre Datei schreiben
  echo "$instances_json" > "$tmpfile_json"
  
  python3 - "${SCRIPT_DIR}" "$tmpfile_json" > "$tmpfile" << 'PYEOF'
import json
import os
import sys

try:
    script_dir = sys.argv[1]
    json_file = sys.argv[2]
    with open(json_file) as f:
        data = json.load(f)
except Exception as e:
    sys.stderr.write(f"Error: {e}\n")
    sys.exit(1)

if not isinstance(data, list) or len(data) == 0:
    sys.exit(1)

# State-Dateien einlesen für Stack-Zuordnung (dynamisch aus stacks.yaml)
try:
    import yaml as _y
    _cfg = _y.safe_load(open(os.path.join(script_dir, 'stacks.yaml')))
    stacks = list(_cfg.get('stacks', {}).keys())
except:
    stacks = ['text', 'text_pro', 'image', 'video', 'video_lora', 'qwen_coder_ablit', 'qwen_opus']
stack_labels = {'text': 'Text', 'text_pro': 'Text Pro', 'image': 'Bild', 'video': 'Video', 'video_lora': 'Video LoRA', 'qwen_coder_ablit': 'Qwen Coder', 'qwen_opus': 'Qwen Opus'}

stack_assignments = {}
for stack in stacks:
    sf = os.path.join(script_dir, f'.vast_instance_{stack}')
    try:
        with open(sf) as f:
            for line in f:
                if 'INSTANCE_ID=' in line:
                    iid = line.split('=')[1].strip().strip('"')
                    stack_assignments[iid] = stack
    except:
        pass

for idx, inst in enumerate(data):
    # ID kann int oder string sein
    iid_raw = inst.get('id')
    if iid_raw is None:
        continue
    iid = str(iid_raw)
    if not iid or iid == 'None':
        continue
        
    # Status kann in verschiedenen Feldern sein
    status = str(inst.get('status') or inst.get('actual_status') or inst.get('cur_state') or 'unknown')[:10]
    gpu = str(inst.get('gpu_name') or inst.get('gpu_name_short') or '-')[:16]

    # SSH Port ermitteln - verschiedene Quellen
    ssh_port = ''
    ssh_host = ''
    
    # Quelle 1: Direkt aus ssh_port/ssh_host Feldern (von instance_to_dict_extended)
    if inst.get('ssh_port'):
        ssh_port = str(inst.get('ssh_port'))
    if inst.get('ssh_host'):
        ssh_host = str(inst.get('ssh_host'))
    
    # Quelle 2: Aus ports["22/tcp"]
    if not ssh_port:
        ports = inst.get('ports', {}) or {}
        if isinstance(ports, dict) and ports.get('22/tcp'):
            try:
                entry_list = ports['22/tcp']
                if isinstance(entry_list, list) and len(entry_list) > 0:
                    entry = entry_list[0]
                    if isinstance(entry, dict):
                        ssh_port = str(entry.get('HostPort', ''))
            except:
                pass
    
    # Quelle 3: Fallback aus Rohfeldern
    if not ssh_port or ssh_port == 'None':
        ssh_port = str(inst.get('ssh_port') or inst.get('machine_dir_ssh_port') or '-')
    
    # Fallback für ssh_host
    if not ssh_host or ssh_host == 'None':
        ssh_host = str(inst.get('public_ipaddr') or inst.get('public_ip') or '-')

    # Stack-Zuordnung
    stack_label = stack_assignments.get(iid, '-')
    if stack_label in stack_labels:
        stack_label = stack_labels[stack_label]

    # Ausgabe mit Pipe-Separator
    print(f"{idx}|{iid}|{status}|{gpu}|{ssh_host}:{ssh_port}|{stack_label}")
PYEOF

  rm -f "$tmpfile_json"

  local selection_data
  selection_data=$(cat "$tmpfile")
  rm -f "$tmpfile"

  # Debug: Python-Ausgabe anzeigen
  # print_err "DEBUG Python output: $selection_data"

  # Prüfen ob Python Ausgabe erfolgreich
  if [[ -z "$selection_data" ]]; then
    print_err "Fehler beim Laden der Instanzen."
    return 0
  fi

  # Instanzen anzeigen
  local idx=0
  local -a inst_ids=()
  while IFS='|' read -r py_idx iid status gpu ssh stack_label; do
    if [[ -n "$iid" && "$iid" != "None" ]]; then
      local stack_display="-"
      if [[ "$stack_label" != "-" && "$stack_label" != "None" ]]; then
        stack_display="${GREEN}${stack_label}${NC}"
      fi
      printf "${BOLD}${WHITE}│${NC}  %-4s %-10s %-10s %-16s %-22s %b\n" "$py_idx" "$iid" "$status" "$gpu" "$ssh" "$stack_display"
      inst_ids+=("$iid")
      idx=$((idx + 1))
    fi
  done <<< "$selection_data"

  if [[ $idx -eq 0 ]]; then
    print_warn "Keine Instanzen gefunden."
    return 0
  fi

  echo -e "${BOLD}${WHITE}├────────────────────────────────────────────────────────────────────────────┤${NC}"
  echo -e "${BOLD}${WHITE}│${NC}  ${YELLOW}[0-$((idx-1))]${NC} Instanz an Stack binden  |  ${YELLOW}[n]${NC} Nichts tun  ${BOLD}${WHITE}│${NC}"
  echo -e "${BOLD}${WHITE}└────────────────────────────────────────────────────────────────────────────┘${NC}"
  echo

  # Auswahl einlesen
  read -r -p "Instanz Nr an Stack binden (oder 'n'): " selection
  
  if [[ "$selection" == "n" || "$selection" == "N" || -z "$selection" ]]; then
    info "Überspringe Zuordnung."
    return 0
  fi

  # Prüfen ob Auswahl gültig
  if ! [[ "$selection" =~ ^[0-9]+$ ]] || [[ "$selection" -ge "$idx" ]]; then
    print_err "Ungültige Auswahl: $selection"
    return 0
  fi

  # Ausgewählte Instanz
  local selected_iid="${inst_ids[$selection]}"
  print_step "Instanz ${selected_iid} wurde ausgewählt."

  # Stack auswählen
  echo
  echo -e "${CYAN}Verfügbare Stacks:${NC}"
  local stacks_arr=($(get_available_stacks))
  local stack_idx=0
  local stack_key
  for stack_key in "${stacks_arr[@]}"; do
    local sf="$(state_file_for "$stack_key")"
    local current_iid="-"
    if [[ -f "$sf" ]]; then
      current_iid=$(grep -oP 'INSTANCE_ID="\K[^"]+' "$sf" 2>/dev/null || echo "-")
    fi
    printf "  [%d] %s (aktuell: %s)\n" "$stack_idx" "$(get_stack_label "$stack_key")" "$current_iid"
    stack_idx=$((stack_idx + 1))
  done
  echo

  read -r -p "Stack Nr auswählen: " stack_sel
  
  if ! [[ "$stack_sel" =~ ^[0-9]+$ ]] || [[ "$stack_sel" -ge "${#stacks_arr[@]}" ]]; then
    print_err "Ungültige Stack-Auswahl."
    return 0
  fi

  local target_stack="${stacks_arr[$stack_sel]}"

  # Bestätigung
  read -r -p "Instanz ${selected_iid} an Stack '$(get_stack_label "$target_stack")' binden? (y/N) " confirm
  if [[ ! "${confirm:-}" =~ ^[Yy]$ ]]; then
    print_warn "Abgebrochen."
    return 0
  fi

  local bind_output bind_rc=0
  bind_output=$(python3 "${VAST_PY}" attach "$target_stack" "$selected_iid" 2>&1) || bind_rc=$?
  if (( bind_rc != 0 )); then
    print_err "Fehler beim Binden der Instanz."
    printf '%s\n' "$bind_output"
    return 0
  fi

  local bind_ip bind_port
  bind_ip="$(read_state_field "$target_stack" "INSTANCE_IP")"
  bind_port="$(read_state_field "$target_stack" "INSTANCE_PORT")"
  if [[ -n "$bind_ip" && -n "$bind_port" ]]; then
    print_ok "Instanz ${selected_iid} erfolgreich an Stack '$(get_stack_label "$target_stack")' gebunden!"
    info "SSH: ${bind_ip}:${bind_port}"
  else
    print_warn "Instanz wurde gebunden, aber SSH-Daten konnten nicht aus dem State gelesen werden."
    printf '%s\n' "$bind_output"
  fi
  return 0
}

# ---------- Stack-Konfiguration aus stacks.yaml ----------

get_available_stacks() {
  python3 -c "import yaml; c=yaml.safe_load(open('${STACKS_YAML}')); print(' '.join(c.get('stacks', {}).keys()))"
}

get_stack_config() {
  local stack="$1"
  local key="$2"
  python3 -c "import yaml; c=yaml.safe_load(open('${STACKS_YAML}')); print(c.get('stacks', {}).get('${stack}', {}).get('${key}', ''))"
}

supports_model_update() {
  case "$1" in
    text|text_pro|qwen_coder_ablit) return 0 ;;
    *) return 1 ;;
  esac
}

update_stack_model_config() {
  local stack="$1"
  local model="$2"
  local file_hint="${3:-}"
  python3 - "$STACKS_YAML" "$stack" "$model" "$file_hint" <<'PY'
import sys
import yaml
from pathlib import Path

path, stack, model, file_hint = sys.argv[1:5]
cfg_path = Path(path)
cfg = yaml.safe_load(cfg_path.read_text(encoding="utf-8")) or {}
stacks = cfg.setdefault("stacks", {})
if stack not in stacks:
    raise SystemExit(f"Unknown stack: {stack}")

stacks[stack]["default_model"] = model
if file_hint:
    stacks[stack]["model_file_hint"] = file_hint

for preset in (cfg.get("presets") or {}).values():
    if isinstance(preset, dict) and preset.get("stack") == stack:
        preset["model"] = model

cfg_path.write_text(
    yaml.safe_dump(cfg, sort_keys=False, allow_unicode=False),
    encoding="utf-8",
)
PY
}

get_stack_label() {
  local stack="$1"
  local label
  label=$(python3 -c "import yaml; c=yaml.safe_load(open('${STACKS_YAML}')); print(c.get('stacks', {}).get('${stack}', {}).get('label', ''))" 2>/dev/null)
  if [[ -z "$label" ]]; then
    case "$stack" in
      text)        echo "llama.cpp Text" ;;
      text_pro)    echo "llama.cpp Pro (H100+)" ;;
      image)       echo "Gradio Image UI" ;;
      image_prompt) echo "FLUX.2 Text-to-Image" ;;
      video)       echo "Wan2.1 Video Studio" ;;
      video_lora)  echo "Wan2.1 Video LoRA Studio" ;;
      qwen_coder_ablit) echo "Qwen3-Coder-Next-abliterated (GLX5090)" ;;
      qwen_opus)   echo "Qwen3.5-27B-Opus-Uncensored (Kostengünstig)" ;;
      *)           echo "$stack" ;;
    esac
  else
    echo "$label"
  fi
}

# ---------- Cache für Health-Daten ----------
declare -A HEALTH_CACHE
CACHE_TIMESTAMP=0
CACHE_TTL=30  # Sekunden

print_step()   { echo -e "${CYAN}▶${NC} $*"; }
print_ok()     { echo -e "${GREEN}✓${NC} $*"; }
print_warn()   { echo -e "${YELLOW}⚠${NC} $*"; }
print_err()    { echo -e "${RED}✗${NC} $*"; }

# ---------- Loading Animations ----------

# Start a background spinner
start_spinner() {
  local msg="${1:-Loading}"
  (
    trap "exit" SIGTERM
    exec </dev/null  # Disconnect from stdin
    local i=0
    while true; do
      printf "\r${CYAN}%s${NC} %s  " "${SPINNER[$((i++ % ${#SPINNER[@]}))]}" "$msg"
      sleep 0.1
    done
  ) &
  echo $!
}

# Stop spinner and clear line
stop_spinner() {
  local pid="${1:-}"
  if [[ -n "$pid" ]]; then
    kill "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
  fi
  printf "\r\033[K"
}

# Progress bar
show_progress() {
  local percent="$1"
  local msg="${2:-}"
  local width=40
  local filled=$(( percent * width / 100 ))
  local empty=$(( width - filled ))
  
  printf "\r${CYAN}["
  printf "%${filled}s" | tr ' ' '█'
  printf "%${empty}s" | tr ' ' '░'
  printf "] ${percent}%% ${msg}${NC}"
  
  if [[ "$percent" -ge 100 ]]; then
    echo
  fi
}

# Animated progress with auto-increment
animate_progress() {
  local msg="${1:-Processing}"
  (
    trap "exit" SIGTERM
    exec </dev/null  # Disconnect from stdin
    local percent=0
    local direction=1
    while true; do
      show_progress "$percent" "$msg"
      sleep 0.2
      percent=$((percent + direction))
      if [[ $percent -ge 95 ]]; then
        direction=-1
      elif [[ $percent -le 5 ]]; then
        direction=1
      fi
    done
  ) &
  echo $!
}

stop_progress() {
  local pid="${1:-}"
  if [[ -n "$pid" ]]; then
    kill "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
  fi
  printf "\r\033[K"
}

# ---------- Vast.ai Instanzen anzeigen ----------

fetch_all_instances_json() {
  if [[ ! -f "${VAST_PY}" ]]; then
    echo "[]"
    return 1
  fi
  python3 "${VAST_PY}" list --json 2>/dev/null || echo "[]"
}

render_vast_overview() {
  box_top
  box_line " ${BOLD}${MAGENTA}VAST.AI INSTANZEN ÜBERSICHT${NC}"
  box_sep

  local json
  json=$(fetch_all_instances_json)

  if [[ "$json" == "[]" ]] || [[ -z "$json" ]]; then
    box_line " ${YELLOW}Keine Instanzen gefunden${NC}"
    box_bottom
    return
  fi

  # Parse JSON with Python and display - pass ANSI codes via printf to ensure interpretation
  local ansi_green ansi_yellow ansi_red ansi_nc
  ansi_green=$(printf '\033[0;32m')
  ansi_yellow=$(printf '\033[1;33m')
  ansi_red=$(printf '\033[0;31m')
  ansi_nc=$(printf '\033[0m')

  # Header line inside box
  printf "│ %b%-8s %-12s %-20s %-8s %-25s %s%b │\n" "$BOLD" "ID" "STATUS" "GPU" "\$/h" "SSH" "STACK" "$NC"

  python3 - "$json" "${SCRIPT_DIR}" "$ansi_green" "$ansi_yellow" "$ansi_red" "$ansi_nc" "$BOX_WIDTH" <<'PYEOF'
import json
import sys
import os

try:
    data = json.loads(sys.argv[1])
    script_dir = sys.argv[2]
    GREEN = sys.argv[3]
    YELLOW = sys.argv[4]
    RED = sys.argv[5]
    NC = sys.argv[6]
    BOX_WIDTH = int(sys.argv[7])
except:
    data = []
    GREEN, YELLOW, RED, NC = '\033[0;32m', '\033[1;33m', '\033[0;31m', '\033[0m'
    BOX_WIDTH = 80

if not data:
    print('Keine Instanzen gefunden')
    sys.exit(0)

# Map local state files to stacks - dynamically from stacks.yaml if available
stacks = {}
stacks_yaml = os.path.join(script_dir, 'stacks.yaml')
available_stacks = ['text', 'text_pro', 'image', 'video', 'video_lora']  # fallback
if os.path.exists(stacks_yaml):
    try:
        import yaml
        with open(stacks_yaml) as f:
            config = yaml.safe_load(f)
            available_stacks = list(config.get('stacks', {}).keys())
    except:
        pass

for stack in available_stacks:
    sf = script_dir + '/.vast_instance_' + stack
    try:
        with open(sf) as f:
            for line in f:
                if 'INSTANCE_ID' in line:
                    iid = line.split('=')[1].strip().strip('"')
                    stacks[iid] = stack
    except:
        pass

inner_width = BOX_WIDTH - 4
for inst in data:
    iid = str(inst.get('id', ''))
    status = str(inst.get('status', 'unknown')).lower()[:12]
    gpu = str(inst.get('gpu_name', ''))[:20]
    dph = str(inst.get('dph_total', inst.get('dph', '-')))[:8]
    ssh_port = str(inst.get('ssh_port', ''))
    ssh_host = str(inst.get('ssh_host', inst.get('public_ip', '-')))
    ssh = f'{ssh_host}:{ssh_port}' if ssh_host != '-' and ssh_port else ssh_host
    stack_tag = stacks.get(iid, '')
    if stack_tag:
        stack_tag = {'text': '[Text]', 'text_pro': '[TextPro]', 'image': '[Bild]', 'image_prompt': '[FLUX2]', 'video': '[Video]', 'video_lora': '[VidLoRA]', 'qwen_coder_ablit': '[QwenCod]', 'qwen_opus': '[QwenOpus]'}.get(stack_tag, '')

    # Color status
    status_colors = {'running': GREEN, 'stopped': YELLOW, 'exited': RED, 'offline': RED}
    status_color = status_colors.get(status, NC)

    line = f'{iid:<8} {status_color}{status:<12}{NC} {gpu:<20} {dph:<8} {ssh:<25} {stack_tag}'
    # Strip ANSI for length calculation
    import re
    clean_line = re.sub(r'\x1b\[[0-9;]*m', '', line)
    padding = inner_width - len(clean_line) - 2  # -2 for leading space
    if padding < 0:
        padding = 0
    print(f'│ {line}{" " * padding} │')
PYEOF

  box_bottom
}

# ---------- Health Check mit Cache ----------

_fetch_stack_health_json() {
  local stack="$1"
  if [[ ! -f "${VAST_PY}" ]]; then
    echo "{}"
    return 1
  fi
  local output
  if output=$(timeout 15 python3 "${VAST_PY}" health "$stack" --json 2>&1); then
    echo "$output"
    return 0
  else
    _fallback_health_json "$stack"
    return 1
  fi
}

_fallback_health_json() {
  local stack="$1"
  local sf="$(state_file_for "$stack")"
  local state_file_exists="false"
  local instance_id=""
  local instance_exists="false"
  local instance_status="unknown"
  local ssh_reachable="false"
  local ready="false"

  if [[ -f "$sf" ]]; then
    state_file_exists="true"
    . "$sf" 2>/dev/null || true
    instance_id="${INSTANCE_ID:-}"
    if [[ -n "$instance_id" ]]; then
      if [[ -f "${VAST_PY}" ]]; then
        local instances_raw
        instances_raw=$(timeout 10 python3 "${VAST_PY}" list --json 2>/dev/null || echo "[]")
        if echo "$instances_raw" | python3 -c "import sys,json; data=json.load(sys.stdin); sys.exit(0 if any(str(i.get('id',''))==sys.argv[1] for i in data) else 1)" "$instance_id" 2>/dev/null; then
          instance_exists="true"
          instance_status=$(echo "$instances_raw" | python3 -c "import sys,json; data=json.load(sys.stdin); [print(i.get('status','unknown')) for i in data if str(i.get('id',''))==sys.argv[1]]" "$instance_id" 2>/dev/null || echo "unknown")
        fi
      fi
      if [[ -n "${INSTANCE_IP:-}" && -n "${INSTANCE_PORT:-}" ]]; then
        if timeout 8 ssh -o StrictHostKeyChecking=no -o ConnectTimeout=3 -p "${INSTANCE_PORT}" "root@${INSTANCE_IP}" "echo test" >/dev/null 2>&1; then
          ssh_reachable="true"
        fi
      fi
    fi
  fi

  [[ "$state_file_exists" == "true" && "$instance_exists" == "true" && "$instance_status" == "running" && "$ssh_reachable" == "true" ]] && ready="true"

  cat <<EOF
{"stack":"$stack","state_file_exists":$state_file_exists,"instance_id":"$instance_id","instance_exists":$instance_exists,"instance_status":"$instance_status","ssh_reachable":$ssh_reachable,"ready":$ready,"missing":[],"suggested_actions":[]}
EOF
}

_parse_health_data() {
  local json="$1"
  python3 - "$json" <<'PYEOF'
import sys, json
try:
    data = json.loads(sys.argv[1])
except:
    data = {}
stack = data.get('stack', '')
state_file_exists = str(data.get('state_file_exists', False)).lower()
instance_id = data.get('instance_id', '')
instance_exists = str(data.get('instance_exists', False)).lower()
instance_status = data.get('instance_status', '')
ssh_reachable = str(data.get('ssh_reachable', False)).lower()
ready = str(data.get('ready', False)).lower()
missing = ','.join(str(m) for m in data.get('missing', []))
suggested = ','.join(str(a) for a in data.get('suggested_actions', []))
print(f'STACK_HEALTH_STACK={stack}')
print(f'STACK_HEALTH_STATE_FILE_EXISTS={state_file_exists}')
print(f'STACK_HEALTH_INSTANCE_ID={instance_id}')
print(f'STACK_HEALTH_INSTANCE_EXISTS={instance_exists}')
print(f'STACK_HEALTH_INSTANCE_STATUS={instance_status}')
print(f'STACK_HEALTH_SSH_REACHABLE={ssh_reachable}')
print(f'STACK_HEALTH_READY={ready}')
print(f'STACK_HEALTH_MISSING_CSV={missing}')
print(f'STACK_HEALTH_SUGGESTED_ACTIONS_CSV={suggested}')
PYEOF
}

get_stack_health() {
  local stack="$1"
  local now=$(date +%s)
  local cache_key="health_${stack}"
  
  # Check cache
  if [[ -n "${HEALTH_CACHE[$cache_key]:-}" ]] && (( now - CACHE_TIMESTAMP < CACHE_TTL )); then
    eval "${HEALTH_CACHE[$cache_key]}"
    return 0
  fi
  
  local json=$(_fetch_stack_health_json "$stack")
  local parsed
  parsed=$(_parse_health_data "$json")
  
  # Cache it
  HEALTH_CACHE[$cache_key]="$parsed"
  CACHE_TIMESTAMP=$now
  
  eval "$parsed"
}

recommend_action_for_stack() {
  local stack="$1"
  get_stack_health "$stack"
  local state_file_exists="$STACK_HEALTH_STATE_FILE_EXISTS"
  local instance_exists="$STACK_HEALTH_INSTANCE_EXISTS"
  local instance_status="$STACK_HEALTH_INSTANCE_STATUS"
  local ssh_reachable="$STACK_HEALTH_SSH_REACHABLE"
  local ready="$STACK_HEALTH_READY"

  if [[ "$state_file_exists" != "true" ]]; then echo "Neu vorbereiten"; return; fi
  if [[ "$instance_exists" != "true" ]]; then echo "State veraltet"; return; fi
  if [[ "$instance_status" != "running" ]]; then echo "Instanz starten"; return; fi
  if [[ "$ssh_reachable" != "true" ]]; then echo "Warten/Reparieren"; return; fi
  if [[ "$ready" != "true" ]]; then echo "Dienst starten"; return; fi
  echo "UI öffnen"
}

status_to_human() {
  local key="$1" value="$2"
  case "$key" in
    state_file_exists) [[ "$value" == "true" ]] && echo "vorhanden" || echo "nicht vorhanden" ;;
    instance_exists) [[ "$value" == "true" ]] && echo "ja" || echo "nein" ;;
    ssh_reachable) [[ "$value" == "true" ]] && echo "erreichbar" || echo "nicht erreichbar" ;;
    ready) [[ "$value" == "true" ]] && echo "bereit" || echo "nicht bereit" ;;
    instance_status) echo "$value" ;;
    *) echo "$value" ;;
  esac
}

# ---------- Render Functions ----------

render_header() {
  clear 2>/dev/null || true
  box_title "AI STUDIO CONSOLE"
  echo
}

render_stack_status_compact() {
  local stack="$1"
  local do_full_check="${2:-false}"
  local label=$(get_stack_label "$stack")
  local sf="$(state_file_for "$stack")"

  # Default values (non-blocking, from state file only)
  local instance_id="" has_state="false" status_text="nicht vorbereitet"
  local status_icon="${RED}${STATUS_BAD}${NC}" ssh_text="-" recommendation="Neu vorbereiten"

  if [[ -f "$sf" ]]; then
    has_state="true"
    instance_id="$(read_state_field "$stack" "INSTANCE_ID")"
    status_text="Status prüfen..."
    status_icon="${YELLOW}${STATUS_WARN}${NC}"
    recommendation="Details im Menü"
  fi

  # Only run full health check if explicitly requested (e.g. menu option [2])
  if [[ "$do_full_check" == "true" && "$has_state" == "true" ]]; then
    get_stack_health "$stack"
    local instance_exists="$STACK_HEALTH_INSTANCE_EXISTS"
    local instance_status="$STACK_HEALTH_INSTANCE_STATUS"
    local ssh_reachable="$STACK_HEALTH_SSH_REACHABLE"
    local ready="$STACK_HEALTH_READY"
    recommendation=$(recommend_action_for_stack "$stack")
    status_text="$instance_status"
    [[ "$instance_exists" != "true" ]] && status_text="nicht gefunden"
    [[ "$ready" == "true" ]] && status_icon="${GREEN}${STATUS_GOOD}${NC}"
    [[ "$ssh_reachable" == "true" ]] && ssh_text="${GREEN}${ICON_OK}${NC}" || ssh_text="${RED}${ICON_BAD}${NC}"
  fi

  printf "  %b %-9s " "$status_icon" "$label"
  printf "${DIM}%-8s${NC}  " "${instance_id:--}"
  local status_color="${YELLOW}"
  [[ "$status_text" == "running" ]] && status_color="${GREEN}"
  [[ "$status_text" == "nicht gefunden" || "$status_text" == "exited" ]] && status_color="${RED}"
  printf "%b%-16s%b  " "$status_color" "$status_text" "$NC"
  printf "SSH: %b  " "$ssh_text"
  printf "${YELLOW}%s${NC}" "$recommendation"
  echo
}

render_status_overview() {
  box_top
  box_line " ${BOLD}STACK STATUS${NC}"
  box_sep

  local stack_key
  for stack_key in $(get_available_stacks); do
    _render_stack_status_quick "$stack_key"
  done

  box_bottom
  echo
}

_render_stack_status_quick() {
  local stack="$1"
  local label=$(get_stack_label "$stack")
  local sf="$(state_file_for "$stack")"
  local instance_id=""
  local has_state="false"
  local instance_status=""

  if [[ -f "$sf" ]]; then
    has_state="true"
    instance_id="$(read_state_field "$stack" "INSTANCE_ID")"
    instance_status="$(read_state_field "$stack" "INSTANCE_STATUS")"
  fi

  # Quick status indicator based on state file only (no SSH check for speed)
  local status_icon="${RED}${STATUS_BAD}${NC}"
  local status_text="nicht vorbereitet"
  local status_color="${DIM}"

  if [[ "$has_state" == "true" && -n "$instance_id" ]]; then
    case "${instance_status:-unknown}" in
      running)
        status_icon="${GREEN}${STATUS_GOOD}${NC}"
        status_text="running"
        status_color="${GREEN}"
        ;;
      stopped|offline|loading|created)
        status_icon="${YELLOW}${STATUS_WARN}${NC}"
        status_text="${instance_status}"
        status_color="${YELLOW}"
        ;;
      exited|error|dead|not_found)
        status_icon="${RED}${STATUS_BAD}${NC}"
        [[ "$instance_status" == "not_found" ]] && status_text="nicht gefunden" || status_text="${instance_status}"
        status_color="${RED}"
        ;;
      *)
        status_icon="${YELLOW}${STATUS_WARN}${NC}"
        status_text="Status prüfen..."
        status_color="${YELLOW}"
        ;;
    esac
  fi

  local line
  line="$(printf "%b %-6s  " "$status_icon" "$label")${DIM}%-8s${NC}  %b%-16s%b  SSH: -  ${DIM}%s${NC}"
  line=$(printf "$line" "${instance_id:--}" "$status_color" "$status_text" "$NC" "Details im Menü")
  box_line "$line"
}

# ---------- Dashboard mit Ampelstatus ----------

render_dashboard() {
  render_header
  box_top
  box_line " ${BOLD}DASHBOARD - Stack Status${NC}"
  box_sep

  # Header line
  box_line " ${BOLD}Stack${NC}        ${BOLD}Instanz${NC}      ${BOLD}Status${NC}       ${BOLD}SSH${NC}    ${BOLD}Service${NC}    ${BOLD}API${NC}      ${BOLD}Tunnel${NC}"

  local stack_key
  for stack_key in $(get_available_stacks); do
    # Health als JSON holen für detaillierte Auswertung
    local health_json
    health_json=$(timeout 12 python3 "${VAST_PY}" health "$stack_key" --json 2>/dev/null || echo '{}')

    local label=$(get_stack_label "$stack_key")
    local label_short="${label}"
    [[ ${#label_short} -gt 11 ]] && label_short="${label_short:0:11}"

    # Einzelne Felder aus JSON extrahieren
    local instance_id=$(echo "$health_json" | jq -r '.instance_id // "-"')
    local instance_status=$(echo "$health_json" | jq -r '.instance_status // "unknown"')
    local ssh_reachable=$(echo "$health_json" | jq -r '.ssh_reachable // false')
    local manifest_exists=$(echo "$health_json" | jq -r '.manifest_exists // false')
    local service_port_open=$(echo "$health_json" | jq -r '.checks.service_port_open // false')
    local http_health_ok=$(echo "$health_json" | jq -r '.checks.http_health_ok // false')
    local ready=$(echo "$health_json" | jq -r '.ready // false')

    local tunnel_status="${DIM}zu${NC}"

    # Tunnel Status: Prüfe ob SSH-Prozess für diesen Stack läuft
    local sf="$(state_file_for "$stack_key")"
    if [[ -f "$sf" ]]; then
      source "$sf" >/dev/null 2>&1 || true
      local instance_ip="${INSTANCE_IP:-}"
      local instance_port="${INSTANCE_PORT:-}"

      if [[ -n "$instance_ip" && -n "$instance_port" ]]; then
        if pgrep -af "ssh.*-L.*-p ${instance_port}.*root@${instance_ip}" >/dev/null 2>&1 || \
           pgrep -af "ssh.*-p ${instance_port}.*${instance_ip}.*-L" >/dev/null 2>&1; then
          tunnel_status="${GREEN}offen${NC}"
        fi
      fi
    fi

    # Icons basierend auf einzelnen Health-Feldern
    local status_icon="${RED}${STATUS_BAD}${NC}"
    [[ "$instance_status" == "running" ]] && status_icon="${GREEN}${STATUS_GOOD}${NC}"
    [[ "$instance_status" == "stopped" || "$instance_status" == "exited" ]] && status_icon="${YELLOW}${STATUS_WARN}${NC}"

    local ssh_icon="${RED}${ICON_BAD}${NC}"
    [[ "$ssh_reachable" == "true" ]] && ssh_icon="${GREEN}${ICON_OK}${NC}"

    # Service Port (separat geprüft)
    local port_icon="${RED}${ICON_BAD}${NC}"
    [[ "$service_port_open" == "true" ]] && port_icon="${GREEN}${ICON_OK}${NC}"

    # API Health (separat geprüft)
    local api_icon="${RED}${ICON_BAD}${NC}"
    [[ "$http_health_ok" == "true" ]] && api_icon="${GREEN}${ICON_OK}${NC}"

    # Truncate instance ID
    local iid_short="${instance_id:--}"
    [[ ${#iid_short} -gt 8 ]] && iid_short="${iid_short:0:8}"
    [[ ${#instance_status} -gt 12 ]] && instance_status="${instance_status:0:12}"

    local line
    line="$(printf "${BOLD}%-11s${NC} " "$label_short")$(printf "${DIM}%-10s${NC} " "$iid_short")$(printf "%b%-12s${NC} " "$status_icon" "$instance_status")$(printf "%-7b" "$ssh_icon")$(printf "%-9b" "$port_icon")$(printf "%-8b" "$api_icon")$(printf "%b" "$tunnel_status")"
    box_line "$line"
  done

  box_sep
  box_line " ${GREEN}${ICON_OK}${NC} = ok  ${YELLOW}${STATUS_WARN}${NC} = Warnung  ${RED}${STATUS_BAD}${NC}/${RED}${ICON_BAD}${NC} = Problem  ${DIM}zu${NC} = kein Tunnel"
  box_bottom
}

# ---------- Control Center ----------

get_stack_actions() {
  local stack="$1"
  get_stack_health "$stack"
  local state_file_exists="$STACK_HEALTH_STATE_FILE_EXISTS"
  local instance_exists="$STACK_HEALTH_INSTANCE_EXISTS"
  local instance_status="$STACK_HEALTH_INSTANCE_STATUS"
  local ssh_reachable="$STACK_HEALTH_SSH_REACHABLE"
  local ready="$STACK_HEALTH_READY"

  if [[ "$state_file_exists" != "true" ]]; then echo "p"; return; fi
  if [[ "$instance_exists" != "true" ]]; then echo "p x"; return; fi
  if [[ "$instance_status" != "running" ]]; then echo "s p x c"; return; fi
  if [[ "$ssh_reachable" != "true" ]]; then echo "r x c"; return; fi
  if [[ "$ready" != "true" ]]; then echo "r o x c"; return; fi
  echo "o r x c"
}

action_description() {
  case "$1" in
    o) echo "Öffnen" ;; r) echo "Reparieren" ;; s) echo "Starten" ;;
    p) echo "Vorbereiten" ;; x) echo "Löschen (lokal)" ;; c) echo "Remote zerstören" ;;
    *) echo "?" ;;
  esac
}

perform_stack_action() {
  local stack="$1" action="$2"
  local label=$(get_stack_label "$stack")

  case "$action" in
    o) print_step "Öffne Tunnel für ${label}..."; open_tunnel_for_stack "$stack" ;;
    r) print_step "Repariere ${label}..."; repair_stack "$stack" && print_ok "Reparatur erfolgreich." || print_err "Reparatur fehlgeschlagen." ;;
    s) print_step "Starte Instanz für ${label}..."; ensure_remote_instance_running "$stack" && print_ok "Instanz gestartet." || print_err "Start fehlgeschlagen." ;;
    p) print_step "Bereite ${label} vor..."; run_manage setup "$stack" && print_ok "Vorbereitung erfolgreich." || print_err "Vorbereitung fehlgeschlagen." ;;
    x) print_step "Lösche State für ${label}..."; run_manage delete "$stack" && print_ok "State entfernt." || print_err "Löschen fehlgeschlagen." ;;
    c) print_step "Zerstöre Remote für ${label}..."; run_manage delete "$stack" --remote && print_ok "Remote zerstört." || print_err "Zerstören fehlgeschlagen." ;;
    *) print_err "Unbekannte Aktion: $action"; return 1 ;;
  esac
}

render_control_center() {
  render_header
  render_vast_overview
  echo
  box_top
  box_line " ${BOLD}STACK CONTROL CENTER${NC}"
  box_sep

  local stack_key
  for stack_key in $(get_available_stacks); do
    get_stack_health "$stack_key"
    local label=$(get_stack_label "$stack_key")
    local state_file_exists="$STACK_HEALTH_STATE_FILE_EXISTS"
    local instance_id="$STACK_HEALTH_INSTANCE_ID"
    local instance_exists="$STACK_HEALTH_INSTANCE_EXISTS"
    local instance_status="$STACK_HEALTH_INSTANCE_STATUS"
    local ssh_reachable="$STACK_HEALTH_SSH_REACHABLE"
    local ready="$STACK_HEALTH_READY"
    local actions=$(get_stack_actions "$stack_key")

    # Status icon
    local status_icon="${GREEN}●${NC}"
    [[ "$ready" != "true" ]] && status_icon="${YELLOW}●${NC}"
    [[ "$instance_exists" != "true" ]] && status_icon="${RED}●${NC}"

    box_line " %b ${label}${NC}"

    local status_color="${GREEN}"
    [[ "$instance_status" != "running" ]] && status_color="${RED}"
    local ssh_icon="${GREEN}✓${NC}"
    [[ "$ssh_reachable" != "true" ]] && ssh_icon="${RED}✗${NC}"

    # Actions
    local actions_display=""
    for (( i=0; i<${#actions}; i++ )); do
      local code="${actions:$i:1}"
      actions_display="${actions_display}${YELLOW}[${code}]${NC} "
    done

    local line="    ${DIM}ID: %-8s${NC}  ${status_color}%s${NC}  SSH: %s  %b"
    line=$(printf "$line" "${instance_id:--}" "$instance_status" "$ssh_icon" "$actions_display")
    box_line "$line"
  done

  box_sep
  box_line " ${BOLD}Aktionen:${NC} ${YELLOW}[t/i/v]+[o/r/s/p/x/c]${NC} | ${YELLOW}[a]${NC} refresh ${YELLOW}[m]${NC} Menü ${YELLOW}[h]${NC} Hilfe ${YELLOW}[q]${NC} Quit"
  box_bottom
}

show_control_center_help() {
  render_header
  box_menu_start "HILFE / TASTENÜBERSICHT"
  box_menu_item " ${BOLD}Stack-Aktionen (2 Buchstaben):${NC}"
  box_menu_item "   1. Buchstabe: ${YELLOW}t${NC}=Text  ${YELLOW}p${NC}=Text Pro  ${YELLOW}i${NC}=Bild  ${YELLOW}f${NC}=FLUX.2"
  box_menu_item "                 ${YELLOW}v${NC}=Video  ${YELLOW}w${NC}=Video LoRA"
  box_menu_item "   2. Buchstabe: ${YELLOW}o${NC}=Öffnen  ${YELLOW}r${NC}=Reparieren  ${YELLOW}s${NC}=Starten"
  box_menu_item "                 ${YELLOW}p${NC}=Vorbereiten  ${YELLOW}x${NC}=Löschen  ${YELLOW}c${NC}=Remote zerstören"
  box_menu_item ""
  box_menu_item "   Beispiele: ${CYAN}to${NC}=Text öffnen  ${CYAN}ir${NC}=Bild reparieren  ${CYAN}fo${NC}=FLUX.2 öffnen"
  box_menu_item "   Verfügbare Stacks: $(get_available_stacks)"
  box_menu_item ""
  box_menu_item " ${BOLD}Globale Aktionen:${NC}"
  box_menu_item "   ${YELLOW}a${NC} = Status aktual    ${YELLOW}m${NC} = Klassisches Menü"
  box_menu_item "   ${YELLOW}h${NC} = Hilfe anzeigen          ${YELLOW}q${NC} = Beenden"
  box_menu_end
  echo
  read -r -p "Enter drücken... " _ || true
}

handle_control_center_input() {
  local input="$1"
  local stack="" action=""

  case "$input" in
    a) print_step "Aktualisiere Status..."; HEALTH_CACHE=(); CACHE_TIMESTAMP=0; return 0 ;;
    m) print_step "Wechsle zum Menü..."; interactive_menu; return 2 ;;
    h) show_control_center_help; return 1 ;;
    q) echo "Beenden."; exit 0 ;;
  esac

  if [[ ${#input} -eq 2 ]]; then
    local first="${input:0:1}" second="${input:1:1}"
    # Dynamische Stack-Zuordnung basierend auf stacks.yaml
    case "$first" in
      t) stack="text" ;;
      p) stack="text_pro" ;;
      i) stack="image" ;;
      f) stack="image_prompt" ;;
      v) stack="video" ;;
      w) stack="video_lora" ;;
      *)
        # Prüfe ob es ein gültiger Stack ist
        local stacks=$(get_available_stacks)
        if [[ " ${stacks} " =~ " ${first} " ]]; then
          stack="$first"
        else
          print_err "Ungültiger Stack: $first (verfügbar: ${stacks})"; return 1
        fi
        ;;
    esac
    case "$second" in
      o|r|s|p|x|c) action="$second" ;;
      *) print_err "Ungültige Aktion: $second"; return 1 ;;
    esac
    local available=$(get_stack_actions "$stack")
    if [[ "$available" != *"$action"* ]]; then
      print_err "Aktion '$action' für $stack nicht verfügbar."
      return 1
    fi
    perform_stack_action "$stack" "$action"
    return 0
  fi

  print_err "Unbekannte Eingabe: $input"
  return 1
}

control_center_menu() {
  while true; do
    render_control_center
    echo -ne "${CYAN}Eingabe:${NC} "
    read -r -e input
    input=$(echo "$input" | tr '[:upper:]' '[:lower:]' | xargs)
    [[ -z "$input" ]] && continue
    handle_control_center_input "$input"
    local ret=$?
    [[ $ret -eq 2 ]] && return
    if [[ $ret -eq 0 ]] || [[ $ret -eq 1 ]]; then
      echo
      read -r -p "Enter drücken... " _ || true
    fi
  done
}

# ---------- Stack Operations ----------

# Check if instance exists and is in a usable state (not Error/exited)
# Returns 0 if running, 1 if dead/missing, 2 if exists but not running (stoppable)
check_instance_api_status() {
  local stack="$1"
  has_state "$stack" || return 1
  local sf="$(state_file_for "$stack")"
  . "$sf" 2>/dev/null || true
  local iid="${INSTANCE_ID:-}"
  [[ -z "$iid" ]] && return 1

  local status_json
  status_json=$(timeout 10 python3 "${VAST_PY}" instance-status "$iid" --json 2>/dev/null || echo '{"exists":false}')

  local exists running
  exists=$(echo "$status_json" | python3 -c "import sys,json; d=json.load(sys.stdin); print(str(d.get('exists',False)).lower())" 2>/dev/null || echo "false")
  running=$(echo "$status_json" | python3 -c "import sys,json; d=json.load(sys.stdin); print(str(d.get('running',False)).lower())" 2>/dev/null || echo "false")

  if [[ "$exists" != "true" ]]; then
    return 1  # Instance doesn't exist
  elif [[ "$running" == "true" ]]; then
    return 0  # Instance is running
  else
    return 2  # Instance exists but not running (e.g. Error, exited, loading)
  fi
}

ensure_remote_instance_exists() {
  local stack="$1"
  has_state "$stack" || { print_warn "Keine State-Datei für $(get_stack_label $stack)."; return 1; }
  
  local label=$(get_stack_label "$stack")
  print_step "Prüfe Remote-Instanz für ${label}..."
  
  # Quick API check first (no SSH, no hanging)
  check_instance_api_status "$stack"
  local api_result=$?
  
  if [[ $api_result -eq 0 ]]; then
    print_ok "Remote-Instanz ${label} läuft."
    return 0
  elif [[ $api_result -eq 1 ]]; then
    print_err "Remote-Instanz ${label} existiert nicht (mehr)."
    return 1
  else
    # Instance exists but not running — try to start it
    print_warn "Instanz ${label} existiert aber läuft nicht. Versuche Start..."
    local sf="$(state_file_for "$stack")"
    . "$sf" 2>/dev/null || true
    
    if timeout 15 vastai start instance "${INSTANCE_ID}" >/dev/null 2>&1; then
      print_step "Startbefehl gesendet, warte auf Running..."
      local i
      for i in $(seq 1 20); do
        check_instance_api_status "$stack" && {
          print_ok "Instanz ${label} läuft jetzt."
          return 0
        }
        sleep 3
      done
    fi
    print_err "Instanz konnte nicht gestartet werden."
    return 1
  fi
}

ensure_remote_instance_running() { ensure_remote_instance_exists "$1"; }

ensure_ssh_reachable() {
  local stack="$1"
  has_state "$stack" || return 1
  local sf="$(state_file_for "$stack")"
  source "$sf" >/dev/null 2>&1 || true
  [[ -z "${INSTANCE_IP:-}" ]] && { print_err "Keine IP."; return 1; }

  local label=$(get_stack_label "$stack")
  local resolved_json resolved_host resolved_port resolved_source

  resolved_json=$(timeout 15 python3 "${VAST_PY}" resolve "$stack" --json 2>/dev/null || echo '{}')
  resolved_host=$(echo "$resolved_json" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('ssh_host',''))" 2>/dev/null || echo "")
  resolved_port=$(echo "$resolved_json" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('ssh_port',''))" 2>/dev/null || echo "")
  resolved_source=$(echo "$resolved_json" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('ssh_source',''))" 2>/dev/null || echo "")

  if [[ -n "$resolved_host" && -n "$resolved_port" ]]; then
    INSTANCE_IP="$resolved_host"
    INSTANCE_PORT="$resolved_port"
    [[ -n "$resolved_source" ]] && SSH_SOURCE="$resolved_source"
  fi
  
  # Ports zum Testen sammeln
  local ports=()
  [[ -n "${INSTANCE_PORT:-}" ]] && ports+=("${INSTANCE_PORT}")

  # Kandidaten aus INSTANCE_PORT_CANDIDATES hinzufügen
  if [[ -n "${INSTANCE_PORT_CANDIDATES:-}" ]]; then
    local p
    for p in ${INSTANCE_PORT_CANDIDATES}; do
      # Nur hinzufügen wenn noch nicht in Liste
      local found=0
      for existing in "${ports[@]}"; do
        [[ "$existing" == "$p" ]] && found=1 && break
      done
      [[ $found -eq 0 ]] && ports+=("$p")
    done
  fi

  # SSH-Verbindung mit allen Ports probieren
  local port
  for port in "${ports[@]}"; do
    print_step "Prüfe SSH zu ${label} (${INSTANCE_IP}:${port})..."
    
    if timeout 15 ssh -o StrictHostKeyChecking=no -o ConnectTimeout=8 -o ServerAliveInterval=5 \
      -p "${port}" "root@${INSTANCE_IP}" "echo ok" >/dev/null 2>&1; then
      # Erfolgreichen Port in State speichern
      INSTANCE_PORT="${port}"
      cat > "$sf" <<EOF
INSTANCE_ID="${INSTANCE_ID:-}"
INSTANCE_IP="${INSTANCE_IP:-}"
INSTANCE_PORT="${port}"
INSTANCE_PORT_CANDIDATES="${port}"
INSTANCE_STATUS="${INSTANCE_STATUS:-running}"
SSH_SOURCE="${SSH_SOURCE:-}"
STACK="${stack}"
EOF
      chmod 600 "$sf"
      print_ok "SSH zu ${label} verbunden auf Port ${port}."
      return 0
    fi
  done

  print_warn "SSH zu ${label} nicht erreichbar (versucht: ${ports[*]})."
  return 1
}

# Stack-spezifische Ports
get_stack_port() {
  local stack="$1"
  local port
  port=$(python3 -c "import yaml; c=yaml.safe_load(open('${STACKS_YAML}')); print(c.get('stacks', {}).get('${stack}', {}).get('service_port', ''))" 2>/dev/null || echo "")
  if [[ -n "$port" && "$port" =~ ^[0-9]+$ ]]; then
    echo "$port"
  else
    # Fallback für bekannte Standardwerte
    case "$stack" in
      text)     echo 8080 ;;
      text_pro) echo 8081 ;;
      image)    echo 7860 ;;
      image_prompt) echo 7863 ;;
      video)    echo 7861 ;;
      video_lora) echo 7862 ;;
      *)        echo 8080 ;;
    esac
  fi
}

# Prüfe ob Service auf Remote läuft (mit timeout)
check_remote_service() {
  local stack="$1"
  local port=$(get_stack_port "$stack")
  local sf="$(state_file_for "$stack")"
  source "$sf" >/dev/null 2>&1 || true
  [[ -z "${INSTANCE_IP:-}" || -z "${INSTANCE_PORT:-}" ]] && return 1
  
  local label=$(get_stack_label "$stack")
  print_step "Prüfe Dienst auf Port ${port}..."
  
  if timeout 15 ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 -p "${INSTANCE_PORT}" \
    "root@${INSTANCE_IP}" "curl -sf --connect-timeout 3 --max-time 5 http://127.0.0.1:${port}/ >/dev/null 2>&1 || curl -sf --connect-timeout 3 --max-time 5 http://127.0.0.1:${port}/v1/models >/dev/null 2>&1 || curl -sf --connect-timeout 3 --max-time 5 http://127.0.0.1:${port}/health >/dev/null 2>&1" 2>/dev/null; then
    print_ok "Dienst läuft auf Port ${port}."
    return 0
  fi
  print_warn "Dienst nicht erreichbar auf Port ${port}."
  return 1
}

# Gründliche Stack-Prüfung mit Service-Check (with timeouts)
check_stack_health_full() {
  local stack="$1"
  has_state "$stack" || return 1
  
  # 1. API status check (non-blocking)
  check_instance_api_status "$stack" || return 1
  
  # 2. SSH prüfen
  ensure_ssh_reachable "$stack" || return 1
  
  # 3. Service-Port prüfen
  check_remote_service "$stack"
}

repair_stack() {
  local stack="$1"
  print_step "Repariere $(get_stack_label $stack) (Setup + Start)..."
  run_manage setup "$stack" && run_manage start "$stack"
}

get_stack_model_hint() {
  local stack="$1"
  get_stack_config "$stack" "model_file_hint"
}

get_image_expected_lora_filenames() {
  python3 - <<'PY'
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

stack_image_assets_need_refresh() {
  local stack="$1"
  [[ "$stack" == "image" ]] || return 1

  has_state "$stack" || return 1
  local sf="$(state_file_for "$stack")"
  source "$sf" >/dev/null 2>&1 || true
  [[ -n "${INSTANCE_IP:-}" && -n "${INSTANCE_PORT:-}" ]] || return 1

  local local_app_hash=""
  [[ -f "${SCRIPT_DIR}/ap_img2img.py" ]] && local_app_hash="$(sha256sum "${SCRIPT_DIR}/ap_img2img.py" | awk '{print $1}')"

  local remote_info remote_app_hash missing=0 expected
  remote_info=$(timeout 20 ssh -T -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o LogLevel=ERROR -o ConnectTimeout=8 -p "${INSTANCE_PORT}" "root@${INSTANCE_IP}" \
    "bash --noprofile --norc -lc 'sha256sum /opt/generative-ui/app.py 2>/dev/null | awk \"{print \\$1}\"; echo ---LORAS---; if [[ -d /opt/models/loras ]]; then find /opt/models/loras -maxdepth 1 -type f -printf \"%f\n\" | sort; fi'" \
    2>/dev/null || true)

  [[ -n "${remote_info}" ]] || return 1
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

stack_model_needs_refresh() {
  local stack="$1"
  local desired_hint
  desired_hint="$(get_stack_model_hint "$stack")"
  [[ -n "$desired_hint" ]] || return 1

  has_state "$stack" || return 1
  local sf="$(state_file_for "$stack")"
  source "$sf" >/dev/null 2>&1 || true
  [[ -n "${INSTANCE_IP:-}" && -n "${INSTANCE_PORT:-}" ]] || return 1

  local remote_info
  remote_info=$(timeout 20 ssh -T -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o LogLevel=ERROR -o ConnectTimeout=8 -p "${INSTANCE_PORT}" "root@${INSTANCE_IP}" \
    "bash --noprofile --norc -lc 'find /opt/models/${stack} -maxdepth 5 -type f \\( -name \"*.gguf\" -o -name \"*.gguf.part*\" \\) -printf \"%f\n\" 2>/dev/null | sort; echo ---ONSTART---; grep -oP \"^MODEL_PATH=\\\"\\\\K[^\\\"]+\" /onstart.sh 2>/dev/null || true'" 2>/dev/null || true)

  [[ -n "$remote_info" ]] || return 1
  local onstart_path
  onstart_path="$(printf '%s\n' "$remote_info" | awk '/^---ONSTART---$/{getline; print; exit}')"
  if [[ "$onstart_path" == *.part* ]]; then
    return 0
  fi
  printf '%s\n' "$remote_info" | grep -Fq "$desired_hint" && return 1
  return 0
}

remote_reset_stack_model() {
  local stack="$1"
  local port
  port="$(get_stack_port "$stack")"

  if ! ensure_remote_instance_exists "$stack"; then
    print_warn "Keine erreichbare Remote-Instanz für $(get_stack_label "$stack"). Nur lokale Konfiguration wurde geändert."
    return 2
  fi
  ensure_remote_instance_running "$stack" || return 1
  ensure_ssh_reachable "$stack" || return 1

  local sf="$(state_file_for "$stack")"
  source "$sf" >/dev/null 2>&1 || true

  print_step "Lösche altes Modell auf Remote für $(get_stack_label "$stack")..."
  if ! timeout 30 ssh -o StrictHostKeyChecking=no -o ConnectTimeout=8 -o ServerAliveInterval=5 \
    -p "${INSTANCE_PORT}" "root@${INSTANCE_IP}" \
    "pids=\$(lsof -ti tcp:${port} 2>/dev/null || true); if [[ -n \"\$pids\" ]]; then kill \$pids >/dev/null 2>&1 || true; sleep 2; kill -9 \$pids >/dev/null 2>&1 || true; fi; rm -rf /opt/models/${stack}; rm -f /onstart.sh /etc/stack_manifest.json /var/log/stack/${stack}.log"; then
    print_err "Remote-Cleanup fehlgeschlagen."
    return 1
  fi

  print_ok "Altes Remote-Modell entfernt."
  return 0
}

update_stack_model_flow() {
  local stack="$1"
  supports_model_update "$stack" || {
    print_warn "Modellwechsel ist aktuell nur für text und text_pro implementiert."
    return 1
  }

  local current_model current_hint new_model new_hint
  current_model="$(get_stack_config "$stack" "default_model")"
  current_hint="$(get_stack_config "$stack" "model_file_hint")"

  render_header
  box_menu_start "MODELL AKTUALISIEREN"
  box_menu_item " Stack: ${CYAN}$(get_stack_label "$stack")${NC}"
  box_menu_item " Aktuell: ${DIM}${current_model}${NC}"
  [[ -n "$current_hint" ]] && box_menu_item " Datei: ${DIM}${current_hint}${NC}"
  box_menu_end
  echo

  read -r -p "Neues Modell-Repo [${current_model}]: " new_model
  new_model="${new_model:-$current_model}"
  [[ -n "$new_model" ]] || { print_err "Modell darf nicht leer sein."; return 1; }

  read -r -p "Datei-Hinweis / Quantisierung [${current_hint}]: " new_hint
  new_hint="${new_hint:-$current_hint}"
  [[ -n "$new_hint" ]] || { print_err "Datei-Hinweis darf nicht leer sein."; return 1; }

  echo
  read -r -p "Modell wirklich umstellen und remote neu installieren? (y/N) " confirm
  [[ "${confirm:-}" =~ ^[Yy]$ ]] || { print_warn "Abgebrochen."; return 1; }

  print_step "Aktualisiere stacks.yaml..."
  if ! update_stack_model_config "$stack" "$new_model" "$new_hint"; then
    print_err "Konnte stacks.yaml nicht aktualisieren."
    return 1
  fi
  print_ok "Konfiguration aktualisiert."

  HEALTH_CACHE=()
  CACHE_TIMESTAMP=0

  if has_state "$stack"; then
    remote_reset_stack_model "$stack"
    case $? in
      1) return 1 ;;
      2)
        print_warn "Nur Konfiguration aktualisiert. Beim nächsten Vorbereiten wird das neue Modell installiert."
        return 0
        ;;
    esac

    print_step "Installiere neues Modell auf Remote..."
    if ! FORCE_MODEL_REINSTALL=1 run_manage setup "$stack"; then
      print_err "Setup für neues Modell fehlgeschlagen."
      return 1
    fi

    print_step "Starte Dienst mit neuem Modell..."
    if ! run_manage start "$stack"; then
      print_err "Start mit neuem Modell fehlgeschlagen."
      return 1
    fi

    print_ok "Neues Modell ist konfiguriert und wurde neu installiert."
    return 0
  fi

  print_warn "Keine gebundene Instanz vorhanden. Das neue Modell wird beim nächsten Vorbereiten installiert."
  return 0
}

ensure_stack_repaired_or_ready() {
  local stack="$1" max_attempts=2
  for attempt in $(seq 1 $max_attempts); do
    print_step "Prüfe $(get_stack_label $stack) (Versuch $attempt/$max_attempts)..."
    ensure_remote_instance_exists "$stack" || { rm -f "$(state_file_for "$stack")"; return 1; }
    ensure_remote_instance_running "$stack" || return 1
    ensure_ssh_reachable "$stack" || return 1
    
    # Gründliche Service-Prüfung
    if check_stack_health_full "$stack"; then
      print_ok "$(get_stack_label $stack) ist bereit."
      return 0
    fi
    
    print_warn "Dienst nicht bereit. Starte Reparatur..."
    if repair_stack "$stack"; then
      print_ok "Reparatur durchgeführt. Erneute Prüfung..."
      if check_stack_health_full "$stack"; then
        print_ok "$(get_stack_label $stack) ist jetzt bereit."
        return 0
      fi
    else
      print_err "Reparatur fehlgeschlagen."
      return 1
    fi
  done
  print_err "$(get_stack_label $stack) konnte nach $max_attempts Versuchen nicht bereit gemacht werden."
  return 1
}

is_local_port_free() {
  local port="$1"
  python3 -c "import socket; s=socket.socket(); s.bind(('', $port)); s.close()" 2>/dev/null
}

pick_local_port_for_stack() {
  local stack="$1" preferred_port
  
  # Bevorzugten Port aus stacks.yaml holen (local_port oder service_port)
  preferred_port=$(python3 -c "import yaml; c=yaml.safe_load(open('${STACKS_YAML}')); s=c.get('stacks', {}).get('${stack}', {}); print(s.get('local_port', s.get('service_port', '')))" 2>/dev/null || echo "")
  
  if [[ -z "$preferred_port" || ! "$preferred_port" =~ ^[0-9]+$ ]]; then
    case "$stack" in 
      text) preferred_port=8080 ;; 
      text_pro) preferred_port=8081 ;; 
      image) preferred_port=7860 ;; 
      image_prompt) preferred_port=7863 ;;
      video)  preferred_port=7861 ;; 
      video_prompt) preferred_port=7861 ;; 
      video_lora) preferred_port=7862 ;;
      *) preferred_port=8080 ;;
    esac
  fi

  local port=$preferred_port
  for offset in $(seq 0 20); do
    local candidate=$((preferred_port + offset))
    is_local_port_free "$candidate" && { echo "$candidate"; return 0; }
  done
  echo "$preferred_port"
}

open_tunnel_safely() {
  local stack="$1"
  local local_port service_port api_remote_port api_tunnel_port

  # Hole Ports aus stacks.yaml
  local_port=$(python3 -c "import yaml; c=yaml.safe_load(open('${STACKS_YAML}')); print(c.get('stacks', {}).get('${stack}', {}).get('local_port', c.get('stacks', {}).get('${stack}', {}).get('service_port', '')))")
  service_port=$(python3 -c "import yaml; c=yaml.safe_load(open('${STACKS_YAML}')); print(c.get('stacks', {}).get('${stack}', {}).get('service_port', ''))")
  api_remote_port=$(python3 -c "import yaml; c=yaml.safe_load(open('${STACKS_YAML}')); s=c.get('stacks', {}).get('${stack}', {}); v=s.get('api_remote_port', s.get('ollama_remote_port')); print(v if v else '')")
  api_tunnel_port=$(python3 -c "import yaml; c=yaml.safe_load(open('${STACKS_YAML}')); s=c.get('stacks', {}).get('${stack}', {}); v=s.get('api_tunnel_port', s.get('ollama_tunnel_port')); print(v if v else '')")

  [[ "$local_port" != "8080" && "$local_port" != "8081" && "$local_port" != "7860" && "$local_port" != "7861" && "$local_port" != "7862"&& "$local_port" != "7863"  ]] && \
    print_warn "Port $local_port statt Standard."
  print_step "Öffne Tunnel auf Port $local_port..."
  local sf="$(state_file_for "$stack")"
  source "$sf" >/dev/null 2>&1 || true
  [[ -z "${INSTANCE_IP:-}" || -z "${INSTANCE_PORT:-}" ]] && { print_err "Fehlende Instanzdaten."; return 1; }

  # SSH-Tunnel im Hintergrund starten (mit -f Option)
  if [[ -n "$api_remote_port" && -n "$api_tunnel_port" ]]; then
    ssh -f -N \
      -L "${local_port}:127.0.0.1:${service_port}" \
      -L "${api_tunnel_port}:127.0.0.1:${api_remote_port}" \
      -p "${INSTANCE_PORT}" "root@${INSTANCE_IP}"
  else
    ssh -f -N \
      -L "${local_port}:127.0.0.1:${service_port}" \
      -p "${INSTANCE_PORT}" "root@${INSTANCE_IP}"
  fi
  
  # Kurze Wartezeit damit Tunnel aufgebaut wird
  sleep 2
  
  # Prüfen ob Tunnel erfolgreich
  if command -v nc >/dev/null 2>&1; then
    if nc -z -w 2 127.0.0.1 "${local_port}" >/dev/null 2>&1; then
      print_ok "Tunnel erstellt: http://127.0.0.1:${local_port}"
      [[ -n "$api_tunnel_port" ]] && print_ok "API-Tunnel: http://127.0.0.1:${api_tunnel_port}"
      return 0
    fi
  else
    # Fallback: Python Port-Check
    if python3 -c "import socket; s=socket.socket(); s.settimeout(2); s.connect(('127.0.0.1', ${local_port})); s.close()" 2>/dev/null; then
      print_ok "Tunnel erstellt: http://127.0.0.1:${local_port}"
      [[ -n "$api_tunnel_port" ]] && print_ok "API-Tunnel: http://127.0.0.1:${api_tunnel_port}"
      return 0
    fi
  fi
  
  print_warn "Tunnel wurde gestartet, aber Port ist nicht erreichbar (noch im Aufbau?)"
  return 0
}

open_tunnel_for_stack() {
  local stack="$1"
  
  # Nur prüfen ob State existiert (keine teuren API/SSH Prüfungen)
  if ! has_state "$stack"; then
    print_err "Keine State-Datei für $(get_stack_label $stack). Bitte zuerst Instanz mieten."
    return 1
  fi
  
  # Instanzdaten laden
  local sf="$(state_file_for "$stack")"
  source "$sf" >/dev/null 2>&1 || true
  
  if [[ -z "${INSTANCE_IP:-}" || -z "${INSTANCE_PORT:-}" ]]; then
    print_err "Fehlende Instanzdaten für $(get_stack_label $stack)."
    return 1
  fi
  
  # Tunnel öffnen (open_tunnel_safely macht eigene minimale Prüfung)
  open_tunnel_safely "$stack"
}

close_tunnel_for_stack() {
  local stack="$1"
  local local_port service_port api_tunnel_port
  
  # Hole Ports aus stacks.yaml
  local_port=$(python3 -c "import yaml; c=yaml.safe_load(open('${STACKS_YAML}')); print(c.get('stacks', {}).get('${stack}', {}).get('local_port', c.get('stacks', {}).get('${stack}', {}).get('service_port', '')))")
  api_tunnel_port=$(python3 -c "import yaml; c=yaml.safe_load(open('${STACKS_YAML}')); s=c.get('stacks', {}).get('${stack}', {}); v=s.get('api_tunnel_port', s.get('ollama_tunnel_port')); print(v if v else '')")
  
  print_step "Schließe SSH-Tunnel für $(get_stack_label $stack)..."
  
  # SSH-Prozesse finden und beenden die auf diesen Ports lauschen
  local killed=0
  
  if [[ -n "$local_port" ]]; then
    # Prozesse finden die auf dem lokalen Port lauschen
    local pids
    pids=$(lsof -ti :${local_port} 2>/dev/null || true)
    if [[ -n "$pids" ]]; then
      for pid in $pids; do
        # Prüfen ob es ein SSH-Tunnel Prozess ist
        if ps -p "$pid" -o comm= 2>/dev/null | grep -q "ssh"; then
          kill "$pid" 2>/dev/null && killed=$((killed + 1))
        fi
      done
    fi
  fi
  
  if [[ -n "$api_tunnel_port" ]]; then
    local pids
    pids=$(lsof -ti :${api_tunnel_port} 2>/dev/null || true)
    if [[ -n "$pids" ]]; then
      for pid in $pids; do
        if ps -p "$pid" -o comm= 2>/dev/null | grep -q "ssh"; then
          kill "$pid" 2>/dev/null && killed=$((killed + 1))
        fi
      done
    fi
  fi
  
  if [[ $killed -gt 0 ]]; then
    print_ok "$killed SSH-Tunnel Prozess(e) beendet."
  else
    print_warn "Keine aktiven SSH-Tunnel gefunden."
  fi
  
  return 0
}

stack_local_url() {
  local stack="$1"
  local local_port service_port api_tunnel_port
  
  local_port=$(python3 -c "import yaml; c=yaml.safe_load(open('${STACKS_YAML}')); s=c.get('stacks', {}).get('${stack}', {}); print(s.get('local_port', s.get('service_port', '')))" 2>/dev/null || echo "")
  service_port=$(python3 -c "import yaml; c=yaml.safe_load(open('${STACKS_YAML}')); s=c.get('stacks', {}).get('${stack}', {}); print(s.get('service_port', ''))" 2>/dev/null || echo "")
  api_tunnel_port=$(python3 -c "import yaml; c=yaml.safe_load(open('${STACKS_YAML}')); s=c.get('stacks', {}).get('${stack}', {}); v=s.get('api_tunnel_port', s.get('ollama_tunnel_port')); print(v if v else '')" 2>/dev/null || echo "")

  if [[ -z "$local_port" || ! "$local_port" =~ ^[0-9]+$ ]]; then
    case "$stack" in
      text)     local_port=8080 ;;
      text_pro) local_port=8081 ;;
      image)    local_port=7860 ;;
      image_prompt) local_port=7863 ;;
      video)    local_port=7861 ;;
      video_lora) local_port=7862 ;;
      *)        local_port=8080 ;;
    esac
  fi

  if [[ "$stack" == "text" || "$stack" == "text_pro" ]]; then
    if [[ -n "$api_tunnel_port" ]]; then
      echo "http://127.0.0.1:${local_port} (API: http://127.0.0.1:${api_tunnel_port})"
    else
      echo "http://127.0.0.1:${local_port}"
    fi
  else
    echo "http://127.0.0.1:${local_port}"
  fi
}

# ---------- Helper ----------

pause() { echo; read -r -p "Enter drücken... " _ || true; }

run_manage() {
  local cmd=("${MANAGE_SCRIPT}" "$@")
  info "→ ${cmd[*]}"
  "${cmd[@]}"
}

run_vast() {
  [[ -f "${VAST_PY}" ]] || die "vast.py fehlt"
  info "→ python3 ${VAST_PY} $*"
  python3 "${VAST_PY}" "$@"
}

cmd_vast() { 
  [[ -f "${VAST_PY}" ]] || die "vast.py fehlt"
  menu_vast_instanzen
}

# ---------- Vast Instanzen Menü ----------

menu_vast_instanzen() {
  while true; do
    render_header
    box_menu_start "VAST.AI INSTANZEN VERWALTEN"

    # Show current instances
    print_step "Deine Instanzen:"
    echo
    python3 "${VAST_PY}" list 2>/dev/null | head -20 || print_warn "Konnte Instanzen nicht laden"
    echo

    box_menu_item " ${YELLOW}[1]${NC} Neue Instanz mieten (text)"
    box_menu_item " ${YELLOW}[2]${NC} Neue Instanz mieten (qwen_opus - RTX)"
    box_menu_item " ${YELLOW}[3]${NC} Neue Instanz mieten (image)"
    box_menu_item " ${YELLOW}[4]${NC} Neue Instanz mieten (video)"
    box_menu_item " ${YELLOW}[5]${NC} Neue Instanz mieten (video_lora)"
    box_menu_item " ${YELLOW}[6]${NC} Instanz starten"
    box_menu_item " ${YELLOW}[7]${NC} Instanz stoppen"
    box_menu_item " ${YELLOW}[8]${NC} Instanz zerstören"
    box_menu_item " ${YELLOW}[9]${NC} SSH zur Instanz"
    box_menu_item " ${YELLOW}[s]${NC} Stack an Instanz binden"
    box_menu_item " ${YELLOW}[a]${NC} Alle Instanzen anzeigen (refresh)"
    box_menu_item " ${YELLOW}[b]${NC} Zurück zum Hauptmenü"
    box_menu_end
    echo -ne "${CYAN}Auswahl:${NC} "
    read -r choice

    case "${choice:-}" in
      1) rent_instance_for_stack "text" ;;
      2) rent_instance_for_stack "qwen_opus" ;;
      3) rent_instance_for_stack "image" ;;
      4) rent_instance_for_stack "video" ;;
      5) rent_instance_for_stack "video_lora" ;;
      6) vast_action_menu "start" ;;
      7) vast_action_menu "stop" ;;
      8) vast_action_menu "destroy" ;;
      9) vast_ssh_shell ;;
      s|S) bind_stack_to_instance ;;
      a|A) continue ;;
      b|B) break ;;
      *) warn "Ungültig"; sleep 1 ;;
    esac
  done
}

rent_instance_for_stack() {
  local stack="$1"
  local label=$(get_stack_label "$stack")

  render_header
  box_menu_start "INSTANZ MIETEN FÜR ${label}"

  print_step "Suche passende Instanz für ${label}..."
  echo -e "${DIM}Dies öffnet das manage_v7_fixed.sh Skript für die Instanz-Suche.${NC}"
  echo

  run_manage rent "$stack"

  if [[ $? -eq 0 ]]; then
    print_ok "Instanz erfolgreich gemietet!"
    print_step "Setup durchführen?"
    read -r -p "Setup jetzt starten? (y/N) " ans
    if [[ "${ans:-}" =~ ^[Yy]$ ]]; then
      run_manage setup "$stack"
      run_manage start "$stack"
    fi
  fi

  pause
}

vast_action_menu() {
  local action="$1"
  local action_text
  case "$action" in
    start) action_text="Starten" ;;
    stop) action_text="Stoppen" ;;
    destroy) action_text="Zerstören" ;;
  esac
  
  render_header
  print_step "Instanz zum ${action_text} auswählen:"
  echo
  
  # List instances with numbers
  python3 -c "
import subprocess
import json

result = subprocess.run(['python3', '${VAST_PY}', 'list', '--json'], capture_output=True, text=True)
try:
    instances = json.loads(result.stdout)
except:
    instances = []

if not instances:
    print('Keine Instanzen gefunden.')
else:
    print(f'{'Nr':<4} {'ID':<8} {'STATUS':<12} {'GPU':<20} {'SSH':<25}')
    print('-' * 70)
    for i, inst in enumerate(instances, 1):
        iid = str(inst.get('id', ''))
        status = str(inst.get('status', 'unknown'))[:12]
        gpu = str(inst.get('gpu_name', ''))[:20]
        ssh = f\"{inst.get('ssh_host', '-')}:{inst.get('ssh_port', '-')}\"
        print(f'{i:<4} {iid:<8} {status:<12} {gpu:<20} {ssh:<25}')
" 2>/dev/null
  
  echo
  read -r -p "Instanz Nr oder ID: " selection
  
  if [[ -z "$selection" ]]; then
    return
  fi
  
  # Get instance ID from selection
  local instance_id
  instance_id=$(python3 -c "
import subprocess
import json
import sys

selection = sys.argv[1]
result = subprocess.run(['python3', '${VAST_PY}', 'list', '--json'], capture_output=True, text=True)
try:
    instances = json.loads(result.stdout)
except:
    print('')
    sys.exit(1)

if selection.isdigit():
    idx = int(selection) - 1
    if 0 <= idx < len(instances):
        print(instances[idx]['id'])
else:
    for inst in instances:
        if str(inst.get('id', '')) == selection:
            print(inst['id'])
            break
" "$selection" 2>/dev/null)
  
  if [[ -z "$instance_id" ]]; then
    print_err "Instanz nicht gefunden."
    pause
    return
  fi
  
  if [[ "$action" == "destroy" ]]; then
    read -r -p "Wirklich zerstören? (y/N) " confirm
    if [[ ! "${confirm:-}" =~ ^[Yy]$ ]]; then
      print_warn "Abgebrochen"
      pause
      return
    fi
  fi
  
  print_step "Führe ${action} für Instanz ${instance_id} aus..."
  python3 "${VAST_PY}" "$action" "$instance_id" --yes 2>/dev/null || python3 "${VAST_PY}" "$action" "$instance_id" 2>/dev/null
  
  if [[ $? -eq 0 ]]; then
    print_ok "Aktion ${action} erfolgreich."
  else
    print_err "Aktion fehlgeschlagen."
  fi
  
  pause
}

vast_ssh_shell() {
  render_header
  print_step "Instanz für SSH auswählen:"
  echo
  
  python3 -c "
import subprocess
import json

result = subprocess.run(['python3', '${VAST_PY}', 'list', '--json'], capture_output=True, text=True)
try:
    instances = json.loads(result.stdout)
except:
    instances = []

if not instances:
    print('Keine Instanzen gefunden.')
else:
    print(f'{'Nr':<4} {'ID':<8} {'STATUS':<12} {'GPU':<20} {'SSH':<25}')
    print('-' * 70)
    for i, inst in enumerate(instances, 1):
        iid = str(inst.get('id', ''))
        status = str(inst.get('status', 'unknown'))[:12]
        gpu = str(inst.get('gpu_name', ''))[:20]
        ssh = f\"{inst.get('ssh_host', '-')}:{inst.get('ssh_port', '-')}\"
        print(f'{i:<4} {iid:<8} {status:<12} {gpu:<20} {ssh:<25}')
" 2>/dev/null
  
  echo
  read -r -p "Instanz Nr oder ID: " selection
  
  if [[ -z "$selection" ]]; then
    return
  fi
  
  local instance_id
  instance_id=$(python3 -c "
import subprocess
import json
import sys

selection = sys.argv[1]
result = subprocess.run(['python3', '${VAST_PY}', 'list', '--json'], capture_output=True, text=True)
try:
    instances = json.loads(result.stdout)
except:
    print('')
    sys.exit(1)

if selection.isdigit():
    idx = int(selection) - 1
    if 0 <= idx < len(instances):
        print(instances[idx]['id'])
else:
    for inst in instances:
        if str(inst.get('id', '')) == selection:
            print(inst['id'])
            break
" "$selection" 2>/dev/null)
  
  if [[ -z "$instance_id" ]]; then
    print_err "Instanz nicht gefunden."
    pause
    return
  fi
  
  print_step "Verbinde zu Instanz ${instance_id}..."
  python3 "${VAST_PY}" ssh "$instance_id"
}

bind_stack_to_instance() {
  render_header
  box_menu_start "STACK AN INSTANZ BINDEN"
  box_menu_end
  echo

  read -r -p "Stack (text/text_pro/image/video/video_lora): " stack
  case "$stack" in
    text|text_pro|image|video|video_lora) ;;
    *) print_err "Ungültiger Stack"; pause; return ;;
  esac

  print_step "Verfügbare Instanzen:"
  python3 "${VAST_PY}" list 2>/dev/null | head -10

  echo
  read -r -p "Instanz ID oder 'last': " inst_sel
  [[ -z "$inst_sel" ]] && return
  
  print_step "Binde ${stack} an Instanz ${inst_sel}..."
  python3 "${VAST_PY}" attach "$stack" "$inst_sel"
  
  if [[ $? -eq 0 ]]; then
    print_ok "Stack ${stack} wurde gebunden."
  else
    print_err "Binden fehlgeschlagen."
  fi
  
  pause
}

run_workflow() {
  [[ -f "${WORKFLOW_SCRIPT}" ]] || die "video_script_full_workflow.sh fehlt"
  info "→ ${WORKFLOW_SCRIPT} $*"
  "${WORKFLOW_SCRIPT}" "$@"
}

# ---------- Commands ----------

cmd_up() {
  local stack="${1:-}"
  [[ -n "$stack" ]] || die "Usage: ./studio.sh up <text|text_pro|image|video|video_lora>"
  case "$stack" in text|text_pro|image|video|video_lora) ;; *) die "Ungültiger Stack: $stack" ;; esac
  ensure_stack_ready "$stack"
}

# Helper: Provision a completely new instance for a stack (rent + setup + start)
provision_new_instance() {
  local stack="$1"
  local label=$(get_stack_label "$stack")

  print_step "Miete neue Instanz fuer ${label}..."
  # Direkt vast.py rent --yes aufrufen (manage_v7_fixed.sh verweigert wenn State existiert)
  if ! python3 "${VAST_PY}" rent "$stack" --yes; then
    print_err "Mieten fehlgeschlagen."
    return 1
  fi

  # State neu laden
  local sf="$(state_file_for "$stack")"
  if [[ ! -f "$sf" ]]; then
    print_err "State-Datei nach Mieten nicht gefunden."
    return 1
  fi
  source "$sf" > /dev/null 2>&1 || true

  print_step "Warte auf SSH-Verbindung (kann 5-10 Min dauern)..."
  local i
  for i in $(seq 1 60); do
    if timeout 10 ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 \
        -p "${INSTANCE_PORT}" "root@${INSTANCE_IP}" "echo ok" > /dev/null 2>&1; then
      print_ok "SSH verbunden."
      break
    fi
    printf '.'
    sleep 10
  done
  echo

  if ! timeout 10 ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 \
      -p "${INSTANCE_PORT}" "root@${INSTANCE_IP}" "echo ok" > /dev/null 2>&1; then
    print_err "SSH nach Warten nicht erreichbar."
    return 1
  fi

  print_step "Fuehre Remote-Setup durch (${label})..."
  if ! run_manage setup "$stack"; then
    print_err "Setup fehlgeschlagen."
    return 1
  fi

  print_step "Starte Dienst fuer ${label}..."
  if ! run_manage start "$stack"; then
    print_warn "Start fehlgeschlagen - Service vielleicht noch nicht bereit."
  fi

  print_ok "${label} wurde erfolgreich provisioniert."
  return 0
}

ensure_stack_ready() {
  local stack="$1"
  local label=$(get_stack_label "$stack")
  print_step "Pruefe Stack ${label}..."

  # 1. Keine State-Datei → neu mieten + einrichten
  if ! has_state "$stack"; then
    print_warn "Keine State-Datei. Miete neue Instanz..."
    provision_new_instance "$stack"
    return $?
  fi

  # State laden
  local sf="$(state_file_for "$stack")"
  source "$sf" > /dev/null 2>&1 || true
  local saved_iid="${INSTANCE_ID:-}"
  local is_manual_binding="false"
  is_manual_state_binding "$stack" && is_manual_binding="true"

  if [[ -z "$saved_iid" ]]; then
    print_warn "Keine Instanz-ID in State-Datei. Miete neue Instanz..."
    provision_new_instance "$stack"
    return $?
  fi

  # 2. Instanz-Status via API pruefen (non-blocking, kein SSH)
  check_instance_api_status "$stack"
  local api_status=$?

  if [[ $api_status -eq 1 ]]; then
    print_warn "Remote-Instanz (${saved_iid}) konnte per API nicht bestätigt werden."

    if ensure_ssh_reachable "$stack"; then
      print_warn "Gebundene Instanz ist per SSH erreichbar. Verwende diese Instanz weiter."
    elif [[ "$is_manual_binding" == "true" ]]; then
      print_err "Manuell gebundene Instanz ist weder per API noch per SSH erreichbar. Es wird bewusst keine neue Instanz gemietet."
      return 1
    else
      # Instanz existiert nicht mehr → State loeschen + neu mieten
      print_warn "Bereinige State und miete neue Instanz..."
      rm -f "$sf"
      provision_new_instance "$stack"
      return $?
    fi
  fi

  if [[ $api_status -eq 2 ]]; then
    # Instanz existiert aber laeuft nicht (Error, exited, etc.)
    # Erst versuchen zu starten
    print_warn "Instanz nicht running. Versuche Start..."
    local start_ok=false

    if timeout 15 vastai start instance "${saved_iid}" > /dev/null 2>&1; then
      local i
      for i in $(seq 1 15); do
        check_instance_api_status "$stack" && { start_ok=true; break; }
        sleep 3
      done
    fi

    if [[ "$start_ok" != "true" ]]; then
      if ensure_ssh_reachable "$stack"; then
        print_warn "Instanz meldet API-seitig nicht running, ist aber per SSH erreichbar. Verwende die gebundene Instanz weiter."
      elif [[ "$is_manual_binding" == "true" ]]; then
        print_err "Manuell gebundene Instanz konnte nicht gestartet werden. Es wird bewusst keine neue Instanz gemietet oder zerstört."
        return 1
      else
        # Konnte nicht neu starten → zerstoeren + neu mieten
        print_warn "Instanz konnte nicht gestartet werden. Zerstoere und miete neu..."
        timeout 10 vastai destroy instance "${saved_iid}" > /dev/null 2>&1 || true
        rm -f "$sf"
        provision_new_instance "$stack"
        return $?
      fi
    fi
    print_ok "Instanz laeuft wieder."
  fi

  # 3. SSH pruefen — Instanz laeuft
  if ! ensure_ssh_reachable "$stack"; then
    print_err "SSH nicht erreichbar trotz running Instanz."
    return 1
  fi

  # 4. Modell auf Remote direkt prüfen, bevor "bereit" gemeldet wird.
  if stack_model_needs_refresh "$stack"; then
    print_warn "Remote-Modell entspricht nicht stacks.yaml. Ersetze Modell..."
    if ! remote_reset_stack_model "$stack"; then
      print_err "Modellwechsel-Cleanup fehlgeschlagen."
      return 1
    fi
    if FORCE_MODEL_REINSTALL=1 run_manage setup "$stack" && run_manage start "$stack"; then
      print_ok "Neues Modell wurde installiert."
      sleep 5
      if check_remote_service "$stack"; then
        print_ok "${label} ist jetzt mit aktuellem Modell bereit."
        return 0
      fi
    fi
    print_err "${label} konnte nach Modellwechsel nicht bereit gemacht werden."
    return 1
  fi

  if stack_image_assets_need_refresh "$stack"; then
    print_warn "Image-App oder konfigurierte LoRAs fehlen/abweichen. Führe Setup + Start durch..."
    if run_manage setup "$stack" && FORCE_STACK_RESTART=1 run_manage start "$stack"; then
      print_ok "Image-Assets wurden aktualisiert."
      sleep 5
      if check_remote_service "$stack"; then
        print_ok "${label} ist jetzt mit aktueller App/LoRA-Konfiguration bereit."
        return 0
      fi
    fi
    print_err "${label} konnte nach Image-Refresh nicht bereit gemacht werden."
    return 1
  fi

  # 5. Service-Pruefung (Port offen?)
  if check_remote_service "$stack"; then
    print_ok "${label} ist bereit."
    return 0
  fi

  # 6. Service nicht bereit → Setup + Start erzwingen
  print_warn "Dienst laeuft nicht. Fuehre Setup + Start durch..."
  if run_manage setup "$stack" && run_manage start "$stack"; then
    print_ok "Setup + Start erfolgreich."
    sleep 5
    if check_remote_service "$stack"; then
      print_ok "${label} ist jetzt bereit."
      return 0
    fi
  fi

  print_err "${label} konnte nicht bereit gemacht werden."
  return 1
}

cmd_open() {
  local stack="${1:-}"
  [[ -n "$stack" ]] || die "Usage: ./studio.sh open <text|text_pro|image|video|video_lora>"
  case "$stack" in text|text_pro|image|video|video_lora) ;; *) die "Ungültiger Stack: $stack" ;; esac
  print_step "Öffne Tunnel für $(get_stack_label $stack)..."
  open_tunnel_for_stack "$stack"
}

cmd_status() {
  echo; info "Instanzstatus:"; "${MANAGE_SCRIPT}" status || true; echo
  [[ -f "${WORKFLOW_SCRIPT}" ]] && { info "Workflow-Status:"; "${WORKFLOW_SCRIPT}" status || true; }
  echo
}

cmd_down() {
  local stack="${1:-}" mode="${2:-local}"
  [[ -n "$stack" ]] || die "Usage: ./studio.sh down <text|text_pro|image|video|video_lora> [local|remote]"
  case "$stack" in text|text_pro|image|video|video_lora) ;; *) die "Ungültiger Stack: $stack" ;; esac
  [[ "$mode" == "remote" ]] && run_manage delete "$stack" --remote || run_manage delete "$stack"
}

cmd_pilot() {
  local start="${1:-1}" end="${2:-10}"
  ensure_stack_ready video
  run_workflow validate
  run_workflow pilot "$start" "$end"
}

cmd_gen() {
  local target="${1:-all}"
  ensure_stack_ready video
  run_workflow validate
  run_workflow gen "$target"
}

cmd_stitch() {
  local output="${1:-final.mp4}"
  run_workflow stitch --output "$output"
}

cmd_init_video() {
  ensure_stack_ready video
  run_workflow init
  run_workflow validate
}

# ---------- NEW: Komfort-Befehle ----------

cmd_go() {
  local stack="${1:-}"
  [[ -n "$stack" ]] || die "Usage: ./studio.sh go <stack>"
  
  # Nutze vast.py go Befehl
  python3 "${VAST_PY}" go "$stack" --open
}

cmd_doctor() {
  local stack="${1:-}"
  
  if [[ -n "$stack" ]]; then
    python3 "${VAST_PY}" doctor "$stack"
  else
    python3 "${VAST_PY}" doctor
  fi
}

menu_doctor() {
  local stack=""
  render_header
  box_menu_start "DOCTOR"
  box_menu_item " Verfügbare Stacks: ${CYAN}$(get_available_stacks)${NC}"
  box_menu_item " Leer lassen = alle Checks"
  box_menu_end
  echo
  read -r -p "Stack für Doctor [leer=alle]: " stack

  if [[ -n "$stack" ]]; then
    case "$stack" in
      text|text_pro|image|image_prompt|video|video_lora) ;;
      *) print_err "Ungültiger Stack: $stack"; pause; return 1 ;;
    esac
  fi

  cmd_doctor "$stack"
  pause
}

cmd_logs() {
  local stack="${1:-}"
  local follow="${2:-}"
  
  [[ -n "$stack" ]] || die "Usage: ./studio.sh logs <stack> [--follow]"
  
  # State laden
  local sf="$(state_file_for "$stack")"
  if [[ ! -f "$sf" ]]; then
    die "Kein State für ${stack} gefunden."
  fi
  
  source "$sf" >/dev/null 2>&1 || true
  [[ -z "${INSTANCE_IP:-}" || -z "${INSTANCE_PORT:-}" ]] && die "Fehlende Instanzdaten."
  
  local ssh_opts="-o StrictHostKeyChecking=no -o ConnectTimeout=10 -p ${INSTANCE_PORT}"
  
  print_step "Logs für ${stack} auf ${INSTANCE_IP}:${INSTANCE_PORT}..."
  echo
  
  # Remote Logs anzeigen
  if [[ "$follow" == "--follow" || "$follow" == "-f" ]]; then
    info "Folge Logs (Strg+C zum Beenden)..."
    ssh ${ssh_opts} root@"${INSTANCE_IP}" "tail -f /var/log/stack/*.log 2>/dev/null || tail -f /var/log/*.log 2>/dev/null || echo 'Keine Logs gefunden'"
  else
    ssh ${ssh_opts} root@"${INSTANCE_IP}" "echo '=== Letzte 50 Zeilen aller Logs ===' && tail -n 50 /var/log/stack/*.log 2>/dev/null || tail -n 50 /var/log/*.log 2>/dev/null || echo 'Keine Logs gefunden'"
  fi
}

cmd_repair() {
  local stack="${1:-}"
  [[ -n "$stack" ]] || die "Usage: ./studio.sh repair <stack>"
  
  print_step "Repariere ${stack}..."
  run_manage repair "$stack"
}

cmd_dashboard() {
  render_dashboard
  echo
  read -r -p "Enter drücken... " _ || true
}

# ---------- Hilfe ----------

cmd_help() {
  cat <<'HELP'
Usage:
  ./studio.sh                 Interaktives Menü
  ./studio.sh go <stack>      Smart Open: macht alles automatisch fertig
  ./studio.sh open <stack>    SSH-Tunnel öffnen
  ./studio.sh dashboard       Dashboard mit Ampelstatus
  ./studio.sh doctor [stack]  Diagnose: lokal und remote prüfen
  ./studio.sh logs <stack> [--follow]  Remote Logs anzeigen
  ./studio.sh repair <stack>  Stack reparieren (Setup + Start)
  ./studio.sh status          Status anzeigen
  ./studio.sh down <stack> [local|remote]
  ./studio.sh init-video      Workflow initialisieren
  ./studio.sh pilot [a] [b]   Pilotlauf (Standard: 1..10)
  ./studio.sh gen <id|all>    Szenen rendern
  ./studio.sh stitch [file]   Clips zusammenfügen
  ./studio.sh vast            Vast-Verwaltung
  ./studio.sh help            Diese Hilfe

Stacks: text | text_pro | qwen_opus (kostengünstig) | image | video | video_lora

Examples:
  ./studio.sh go text         # Vollautomatisch: mieten, starten, tunneln
  ./studio.sh go video -o     # Mit Browser öffnen
  ./studio.sh doctor text     # Diagnose für text Stack
  ./studio.sh logs video -f   # Logs im Follow-Mode
  ./studio.sh repair image    # Image Stack reparieren
HELP
}

# ---------- Menüs ----------

menu_stack_actions() {
  local stack="$1" stack_name stack_model

  case "$stack" in
    text)        stack_name="Text" ;;
    text_pro)    stack_name="Text Pro" ;;
    image)       stack_name="Bild" ;;
    image_prompt) stack_name="FLUX.2 T2I" ;;
    video)       stack_name="Video" ;;
    video_lora)  stack_name="Video LoRA" ;;
    qwen_coder_ablit) stack_name="Qwen Coder (GLX5090)" ;;
    qwen_opus)   stack_name="Qwen Opus (RTX)" ;;
  esac

  while true; do
    stack_model="$(get_stack_config "$stack" "default_model")"
    render_header
    box_menu_start "${stack_name}-MENÜ"
    box_menu_item " Modell: ${CYAN}${stack_model}${NC}"
    box_sep
    render_stack_status_compact "$stack" false
    box_sep
    box_menu_item " ${YELLOW}[1]${NC} Automatisch vorbereiten    ${YELLOW}[2]${NC} Status aktualisieren"
    box_menu_item " ${YELLOW}[3]${NC} Tunnel/UI öffnen           ${YELLOW}[4]${NC} Tunnel schließen"
    box_menu_item " ${YELLOW}[5]${NC} Lokale State löschen       ${YELLOW}[6]${NC} Remote zerstören"
    if supports_model_update "$stack"; then
      box_menu_item " ${YELLOW}[7]${NC} Modell aktualisieren       ${YELLOW}[b]${NC} Zurück"
    else
      box_menu_item " ${YELLOW}[b]${NC} Zurück"
    fi
    box_menu_end
    echo -ne "${CYAN}Auswahl:${NC} "
    read -r choice
    case "${choice:-}" in
      1) ensure_stack_ready "$stack" || true; pause ;;
      2)
        print_step "Aktualisiere Status..."
        HEALTH_CACHE=()
        CACHE_TIMESTAMP=0
        if refresh_all_stack_states "true"; then
          render_stack_status_compact "$stack" true
        fi
        pause
        ;;
      3) open_tunnel_for_stack "$stack" || true; pause ;;
      4) close_tunnel_for_stack "$stack" || true; pause ;;
      5) run_manage delete "$stack" || true; pause ;;
      6) run_manage delete "$stack" --remote || true; pause ;;
      7)
        if supports_model_update "$stack"; then
          update_stack_model_flow "$stack" || true
          pause
        else
          warn "Ungültig"
          sleep 1
        fi
        ;;
      b|B) break ;;
      *) warn "Ungültig"; sleep 1 ;;
    esac
  done
}

menu_video_workflow() {
  while true; do
    render_header
    box_menu_start "VIDEO WORKFLOW"
    box_menu_item " ${YELLOW}[1]${NC} Initialisieren + validieren     ${YELLOW}[2]${NC} Pilotlauf 1..10"
    box_menu_item " ${YELLOW}[3]${NC} Eigenen Pilotbereich            ${YELLOW}[4]${NC} Einzelne Szene"
    box_menu_item " ${YELLOW}[5]${NC} Alle Szenen rendern             ${YELLOW}[6]${NC} Clips zusammenfügen"
    box_menu_item " ${YELLOW}[7]${NC} Workflow-Status                 ${YELLOW}[b]${NC} Zurück"
    box_menu_end
    echo -ne "${CYAN}Auswahl:${NC} "
    read -r choice
    case "${choice:-}" in
      1) cmd_init_video; pause ;;
      2) cmd_pilot 1 10; pause ;;
      3) read -r -p "Start-ID: " s; read -r -p "End-ID: " e; cmd_pilot "${s:-1}" "${e:-10}"; pause ;;
      4) read -r -p "Szenen-ID: " id; [[ -n "$id" ]] && cmd_gen "$id" || warn "Keine ID"; pause ;;
      5) cmd_gen all; pause ;;
      6) read -r -p "Ausgabedatei [final.mp4]: " out; cmd_stitch "${out:-final.mp4}"; pause ;;
      7) run_workflow status; pause ;;
      b|B) break ;;
      *) warn "Ungültig"; sleep 1 ;;
    esac
  done
}

interactive_menu() {
  while true; do
    render_status_overview
    box_menu_start "HAUPTMENÜ"
    box_menu_item " ${YELLOW}[1]${NC} Qwen Coder (GLX5090) ${YELLOW}[2]${NC} Qwen Opus (RTX)    ${YELLOW}[3]${NC} Bild-UI"
    box_menu_item " ${YELLOW}[4]${NC} FLUX.2 T2I         ${YELLOW}[5]${NC} Video-UI             ${YELLOW}[6]${NC} Video LoRA UI"
    box_menu_item " ${YELLOW}[7]${NC} Video-Workflow     ${YELLOW}[8]${NC} Vast-Instanzen       ${YELLOW}[c]${NC} Control Center"
    box_menu_item " ${YELLOW}[d]${NC} Dashboard          ${YELLOW}[g]${NC} Go (Smart Open)      ${YELLOW}[D]${NC} Doctor"
    box_menu_item " ${YELLOW}[l]${NC} Logs               ${YELLOW}[R]${NC} Repair               ${YELLOW}[r]${NC} Status aktual"
    box_menu_item " ${YELLOW}[h]${NC} Hilfe              ${YELLOW}[q]${NC} Beenden"
    box_menu_end
    echo -ne "${CYAN}Auswahl:${NC} "
    read -r choice
    case "${choice:-}" in
      1) menu_stack_actions qwen_coder_ablit ;;
      2) menu_stack_actions qwen_opus ;;
      3) menu_stack_actions image ;;
      4) menu_stack_actions image_prompt ;;
      5) menu_stack_actions video ;;
      6) menu_stack_actions video_lora ;;
      7) menu_video_workflow ;;
      8) cmd_vast ;;
      c|C) control_center_menu ;;
      d) cmd_dashboard ;;
      g|G) read -r -p "Stack (text|text_pro|image|image_prompt|video|video_lora): " s; cmd_go "$s" ;;
      D) menu_doctor ;;
      l|L) read -r -p "Stack: " s; cmd_logs "$s" ;;
      r) print_step "Aktualisiere Status..."; HEALTH_CACHE=(); CACHE_TIMESTAMP=0; refresh_all_stack_states "true"; pause ;;
      R) print_step "Repariere Stack..."; read -r -p "Stack: " s; cmd_repair "$s" ;;
      h|H) cmd_help; pause ;;
      q|Q) exit 0 ;;
      *) warn "Ungültig"; sleep 1 ;;
    esac
  done
}

# ---------- Main ----------

main() {
  local cmd="${1:-menu}"
  shift || true

  # Beim Start immer Vast-Übersicht anzeigen
  if [[ "$cmd" == "menu" ]]; then
    # Welcome message
    box_title "AI STUDIO CONSOLE"
    echo

    # WICHTIG: Zuerst State-Dateien mit Live-API-Daten aktualisieren (automatisch, nicht interaktiv)
    refresh_all_stack_states "false"
    echo

    # Load and display Vast instances
    print_step "Lade Vast.ai Instanzen..."
    render_vast_overview
    echo

    # Quick status
    print_step "Lade Stack Status..."
    render_status_overview
    echo
  fi

  case "$cmd" in
    menu) interactive_menu ;;
    up) cmd_up "$@" ;;
    open) cmd_open "$@" ;;
    go) cmd_go "$@" ;;
    dashboard) cmd_dashboard ;;
    doctor) cmd_doctor "$@" ;;
    logs) cmd_logs "$@" ;;
    repair) cmd_repair "$@" ;;
    status) cmd_status ;;
    down) cmd_down "$@" ;;
    init-video) cmd_init_video ;;
    pilot) cmd_pilot "$@" ;;
    gen) cmd_gen "$@" ;;
    stitch) cmd_stitch "$@" ;;
    vast) cmd_vast ;;
    control) control_center_menu ;;
    help|-h|--help) cmd_help ;;
    *) err "Unbekannter Befehl: $cmd"; echo; cmd_help; exit 1 ;;
  esac
}

main "$@"
