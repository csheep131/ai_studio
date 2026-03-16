#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKFLOW_CONF="${WORKFLOW_CONF:-${SCRIPT_DIR}/workflow.conf}"
STATE_FILE="${SCRIPT_DIR}/.vast_instance_video"
WORKFLOW_STATE_FILE="${SCRIPT_DIR}/.video_workflow_state.json"
BLUEPRINT_FILE="${BLUEPRINT_FILE:-${SCRIPT_DIR}/prnszene.txt}"

die() { echo "ERROR: $*" >&2; exit 1; }
log() { echo "==> $*"; }
need() { command -v "$1" >/dev/null 2>&1 || die "Missing dependency: $1"; }

need bash
need python3
need jq
need ssh
need scp

load_env_file() {
  local env_file="${SCRIPT_DIR}/.env"
  if [[ -f "${env_file}" ]]; then
    set -a
    # shellcheck disable=SC1090
    source "${env_file}"
    set +a
  fi
}

load_env_file

create_default_workflow_conf() {
  cat > "${WORKFLOW_CONF}" <<'EOF_CONF'
# video_script_full_workflow.sh configuration

# Paths relative to repository root
MASTER_IMAGES_DIR="master_images"
OUTPUT_DIR="video_output"
SCENES_FILE="scenes.json"

# Remote settings
REMOTE_WORKDIR="/root/video_workflow"
REMOTE_RUNS_BASE="/root/video_runs"
REMOTE_I2V_SCRIPT="/opt/video-studio/video_i2v.py"
REMOTE_PYTHON="/opt/video-studio/venv/bin/python"

# I2V model
I2V_MODEL="Wan-AI/Wan2.1-I2V-14B-720P-Diffusers"

# Sticky rendering params
FPS=24
CLIP_SECONDS=8
STEPS=30
GUIDANCE=5.0
SEED_BASE=42
WIDTH=832
HEIGHT=480

# Prompt style defaults
MASTER_COLOR_LOOK="Warm gold tones, soft blue neon accents, cinematic soft glow"
NEGATIVE_PROMPT="blurry, low quality, lowres, artifacts, watermark, text, logo, distorted anatomy, flicker"
CAMERA_STYLE="cinematic composition, soft focus, subtle dolly movement"

# Reference image mapping
REF_ELENA_FRONT="elena_front.png"
REF_ELENA_SIDE="elena_side.png"
REF_MARKUS_FRONT="markus_front.png"
REF_MARKUS_ENV="markus_env.png"
EOF_CONF
}

load_workflow_conf() {
  [[ -f "${WORKFLOW_CONF}" ]] || die "Missing ${WORKFLOW_CONF} (run: $0 init)"
  # shellcheck disable=SC1090
  source "${WORKFLOW_CONF}"
  : "${MASTER_IMAGES_DIR:?}" "${OUTPUT_DIR:?}" "${SCENES_FILE:?}" "${I2V_MODEL:?}"
  : "${FPS:?}" "${CLIP_SECONDS:?}" "${STEPS:?}" "${GUIDANCE:?}" "${SEED_BASE:?}"
  : "${REMOTE_WORKDIR:?}" "${REMOTE_RUNS_BASE:?}" "${REMOTE_I2V_SCRIPT:?}" "${REMOTE_PYTHON:?}"
}

load_instance_state() {
  [[ -f "${STATE_FILE}" ]] || die "Missing ${STATE_FILE}. Run: ./manage_v7_fixed.sh use video <id>"
  # shellcheck disable=SC1090
  source "${STATE_FILE}"
  : "${INSTANCE_ID:?}" "${INSTANCE_IP:?}" "${INSTANCE_PORT:?}"
}

ssh_remote() {
  local cmd="$1"
  ssh -o StrictHostKeyChecking=no -o ConnectTimeout=20 -o ServerAliveInterval=30 -o ServerAliveCountMax=6 \
    -p "${INSTANCE_PORT}" "root@${INSTANCE_IP}" "${cmd}"
}

scp_to_remote() {
  local src="$1" dst="$2"
  if [[ -d "${src}" ]]; then
    scp -r -o StrictHostKeyChecking=no -o ConnectTimeout=20 -P "${INSTANCE_PORT}" "${src}" "root@${INSTANCE_IP}:${dst}"
  else
    scp -o StrictHostKeyChecking=no -o ConnectTimeout=20 -P "${INSTANCE_PORT}" "${src}" "root@${INSTANCE_IP}:${dst}"
  fi
}

scp_from_remote() {
  local src="$1" dst="$2"
  scp -o StrictHostKeyChecking=no -o ConnectTimeout=20 -P "${INSTANCE_PORT}" "root@${INSTANCE_IP}:${src}" "${dst}"
}

make_prompt_from_scene() {
  local scene_id="$1"
  jq -r --argjson id "${scene_id}" --arg camera "${CAMERA_STYLE}" --arg look "${MASTER_COLOR_LOOK}" '
    .scenes[] | select(.id==$id) |
    "Subject: " + .subject + "\n" +
    "Action: " + .keywords + "\n" +
    "Environment: " + (.environment // "cinematic boutique interior") + ", " + $look + "\n" +
    "Camera: " + $camera + "\n" +
    "Parameters: " + ((.fps|tostring) + " FPS, " + (.seconds|tostring) + " seconds, high fidelity texture")
  ' "${SCRIPT_DIR}/${SCENES_FILE}"
}

create_scenes_from_blueprint() {
  [[ -f "${BLUEPRINT_FILE}" ]] || die "Missing ${BLUEPRINT_FILE}"
  python3 - "${BLUEPRINT_FILE}" "${SCRIPT_DIR}/${SCENES_FILE}" "${SEED_BASE}" "${FPS}" "${CLIP_SECONDS}" <<'PY'
import json
import re
import sys
from pathlib import Path

src = Path(sys.argv[1])
dst = Path(sys.argv[2])
seed_base = int(sys.argv[3])
fps = int(sys.argv[4])
seconds = float(sys.argv[5])

lines = [l.strip() for l in src.read_text(encoding="utf-8").splitlines()]
scenes = []
i = 0
while i < len(lines):
    line = lines[i]
    if re.fullmatch(r"\d{2}", line or ""):
        sid = int(line)
        visual = ""
        keywords = ""
        j = i + 1
        while j < len(lines) and not lines[j]:
            j += 1
        if j < len(lines):
            visual = lines[j]
        j += 1
        while j < len(lines) and not lines[j]:
            j += 1
        if j < len(lines):
            keywords = lines[j]
        i = j

        text = f"{visual} {keywords}".lower()
        if "elena" in text and "markus" in text:
            ref = "markus_env"
            subject = "Elena and Markus"
        elif "elena" in text:
            ref = "elena_front"
            subject = "Elena"
        elif "markus" in text:
            ref = "markus_front"
            subject = "Markus"
        elif any(x in text for x in ["exterieur", "location", "setting", "atmosphere", "environment", "space"]):
            ref = "markus_env"
            subject = "Elena and Markus"
        elif "close" in text or "detail" in text:
            ref = "elena_side"
            subject = "Elena"
        else:
            ref = "markus_env"
            subject = "Elena and Markus"

        act = ((sid - 1) // 15) + 1
        scene = {
            "id": sid,
            "act": act,
            "visual_focus": visual,
            "keywords": keywords,
            "ref": ref,
            "subject": subject,
            "environment": "boutique interior, rain ambience, cinematic soft glow",
            "seed": seed_base + sid,
            "fps": fps,
            "seconds": seconds,
        }
        scenes.append(scene)
    i += 1

if not scenes:
    raise SystemExit("No scenes parsed from blueprint file.")

payload = {"scenes": scenes}
dst.write_text(json.dumps(payload, ensure_ascii=True, indent=2) + "\n", encoding="utf-8")
print(f"Generated {len(scenes)} scenes -> {dst}")
PY
}

create_example_blueprint() {
  local blueprint="${1:-${BLUEPRINT_FILE}}"
  cat > "${blueprint}" <<'EOF_BP'
01
Elena enters the boutique through rain-soaked glass doors, neon reflections sliding over polished marble and brass details.
arrival, rain, boutique interior, neon reflections, Elena, cinematic entrance

02
Markus stands near the back wall of the atelier, framed by mirrors, dark wood shelves, and warm practical lights.
Markus, interior portrait, reflective mirrors, elegant tailoring room, quiet tension

03
Close side profile of Elena touching a fabric rack while the city glow spills softly across her face.
Elena, close detail, fabric textures, blue neon, warm gold highlights, emotional pause

04
Elena and Markus face each other at the center of the boutique while rain streaks across the front window behind them.
Elena and Markus, two-shot, confrontation, boutique atmosphere, rain ambience, dramatic mood

05
Wide environment shot of the empty boutique after closing time, with reflections, soft haze, and a cinematic blue-gold palette.
environment, space, atmosphere, boutique interior, closing time, reflective floor, cinematic glow
EOF_BP
}

cmd_init() {
  [[ -f "${WORKFLOW_CONF}" ]] || { log "Creating workflow.conf"; create_default_workflow_conf; }
  load_workflow_conf

  mkdir -p "${SCRIPT_DIR}/${MASTER_IMAGES_DIR}"
  mkdir -p "${SCRIPT_DIR}/${OUTPUT_DIR}"

  if [[ ! -f "${BLUEPRINT_FILE}" ]]; then
    log "Creating example blueprint at ${BLUEPRINT_FILE}"
    create_example_blueprint "${BLUEPRINT_FILE}"
  fi

  if [[ ! -f "${SCRIPT_DIR}/${SCENES_FILE}" ]]; then
    log "Creating ${SCENES_FILE} from ${BLUEPRINT_FILE}"
    create_scenes_from_blueprint
  else
    log "${SCENES_FILE} already exists, not overwriting"
  fi

  cat <<EOF
Init complete.
- Config      : ${WORKFLOW_CONF}
- Scenes file : ${SCRIPT_DIR}/${SCENES_FILE}
- Images dir  : ${SCRIPT_DIR}/${MASTER_IMAGES_DIR}
- Output dir  : ${SCRIPT_DIR}/${OUTPUT_DIR}
EOF
}

cmd_validate() {
  load_workflow_conf
  load_instance_state

  [[ -f "${SCRIPT_DIR}/${SCENES_FILE}" ]] || die "Missing scenes file: ${SCENES_FILE}"
  [[ -d "${SCRIPT_DIR}/${MASTER_IMAGES_DIR}" ]] || die "Missing master images dir: ${MASTER_IMAGES_DIR}"

  for f in "${REF_ELENA_FRONT}" "${REF_ELENA_SIDE}" "${REF_MARKUS_FRONT}" "${REF_MARKUS_ENV}"; do
    [[ -f "${SCRIPT_DIR}/${MASTER_IMAGES_DIR}/${f}" ]] || die "Missing master image: ${MASTER_IMAGES_DIR}/${f}"
  done

  jq -e '
    has("scenes") and (.scenes|type=="array") and (.scenes|length>0) and
    (all(.scenes[]; has("id") and has("ref") and has("seed") and has("keywords")))
  ' "${SCRIPT_DIR}/${SCENES_FILE}" >/dev/null || die "Invalid scenes.json schema"

  local dupe
  dupe="$(jq -r '[.scenes[].id] | group_by(.)[] | select(length>1) | .[0]' "${SCRIPT_DIR}/${SCENES_FILE}" | head -n1 || true)"
  [[ -z "${dupe}" ]] || die "Duplicate scene id found: ${dupe}"

  ssh_remote "echo remote_ok" >/dev/null || die "Remote SSH check failed"
  ssh_remote "test -d /opt/video-studio || (echo '/opt/video-studio missing' && exit 1)" >/dev/null || die "Remote /opt/video-studio missing"
  ssh_remote "test -x ${REMOTE_PYTHON} || (echo '${REMOTE_PYTHON} missing' && exit 1)" >/dev/null || die "Remote python missing"

  echo "Validation passed."
}

ensure_remote_i2v_script() {
  load_workflow_conf
  load_instance_state

  ssh_remote "mkdir -p ${REMOTE_WORKDIR}/master_images"
  if [[ -f "${SCRIPT_DIR}/video_i2v.py" ]]; then
    scp_to_remote "${SCRIPT_DIR}/video_i2v.py" "${REMOTE_I2V_SCRIPT}"
    ssh_remote "chmod +x ${REMOTE_I2V_SCRIPT}"
  else
    ssh_remote "test -x ${REMOTE_I2V_SCRIPT} || (echo '${REMOTE_I2V_SCRIPT} missing on remote' && exit 1)"
  fi
}

ref_file_for_key() {
  local ref="$1"
  case "${ref}" in
    elena_front) echo "${REF_ELENA_FRONT}" ;;
    elena_side) echo "${REF_ELENA_SIDE}" ;;
    markus_front) echo "${REF_MARKUS_FRONT}" ;;
    markus_env) echo "${REF_MARKUS_ENV}" ;;
    *) die "Unknown ref key in scenes file: ${ref}" ;;
  esac
}

save_workflow_state() {
  local run_id="$1" remote_dir="$2" local_dir="$3"
  cat > "${WORKFLOW_STATE_FILE}" <<EOF_STATE
{
  "run_id": "${run_id}",
  "remote_dir": "${remote_dir}",
  "local_dir": "${local_dir}",
  "updated_at": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
}
EOF_STATE
}

run_one_scene() {
  local scene_id="$1" run_id="$2"
  local scene_json ref ref_file prompt negative seed fps seconds out_remote out_local qprompt qnegative qmodel qimage qout
  scene_json="$(jq -c --argjson id "${scene_id}" '.scenes[] | select(.id==$id)' "${SCRIPT_DIR}/${SCENES_FILE}")"
  [[ -n "${scene_json}" ]] || die "Scene ${scene_id} not found in ${SCENES_FILE}"

  ref="$(printf "%s" "${scene_json}" | jq -r '.ref')"
  ref_file="$(ref_file_for_key "${ref}")"
  [[ -f "${SCRIPT_DIR}/${MASTER_IMAGES_DIR}/${ref_file}" ]] || die "Missing reference image for scene ${scene_id}: ${MASTER_IMAGES_DIR}/${ref_file}"

  prompt="$(make_prompt_from_scene "${scene_id}")"
  negative="$(printf "%s" "${scene_json}" | jq -r '.negative // empty')"
  if [[ -z "${negative}" ]]; then
    negative="${NEGATIVE_PROMPT}"
  fi
  seed="$(printf "%s" "${scene_json}" | jq -r '.seed')"
  fps="$(printf "%s" "${scene_json}" | jq -r '.fps // empty')"
  seconds="$(printf "%s" "${scene_json}" | jq -r '.seconds // empty')"
  [[ -n "${fps}" ]] || fps="${FPS}"
  [[ -n "${seconds}" ]] || seconds="${CLIP_SECONDS}"

  out_remote="${REMOTE_RUNS_BASE}/full_workflow_${run_id}/scene_$(printf "%03d" "${scene_id}").mp4"
  out_local="${SCRIPT_DIR}/${OUTPUT_DIR}/${run_id}/scene_$(printf "%03d" "${scene_id}").mp4"

  qmodel="$(printf '%q' "${I2V_MODEL}")"
  qimage="$(printf '%q' "${REMOTE_WORKDIR}/master_images/${ref_file}")"
  qprompt="$(printf '%q' "${prompt}")"
  qnegative="$(printf '%q' "${negative}")"
  qout="$(printf '%q' "${out_remote}")"

  log "Generating scene ${scene_id} -> ${out_remote}"
  ssh_remote "mkdir -p ${REMOTE_RUNS_BASE}/full_workflow_${run_id}"
  ssh_remote "HF_TOKEN=$(printf '%q' "${HF_TOKEN:-}") ${REMOTE_PYTHON} ${REMOTE_I2V_SCRIPT} \
    --model ${qmodel} \
    --image ${qimage} \
    --prompt ${qprompt} \
    --negative ${qnegative} \
    --output ${qout} \
    --steps ${STEPS} \
    --guidance ${GUIDANCE} \
    --fps ${fps} \
    --seconds ${seconds} \
    --seed ${seed} \
    --width ${WIDTH} \
    --height ${HEIGHT}"

  mkdir -p "$(dirname "${out_local}")"
  scp_from_remote "${out_remote}" "${out_local}"
}

cmd_gen() {
  local selector="${1:-all}"
  local run_id ids remote_run_dir local_run_dir
  load_workflow_conf
  load_instance_state
  cmd_validate
  ensure_remote_i2v_script

  scp_to_remote "${SCRIPT_DIR}/${MASTER_IMAGES_DIR}" "${REMOTE_WORKDIR}/"

  run_id="$(date +"%Y%m%d_%H%M%S")"
  remote_run_dir="${REMOTE_RUNS_BASE}/full_workflow_${run_id}"
  local_run_dir="${SCRIPT_DIR}/${OUTPUT_DIR}/${run_id}"
  mkdir -p "${local_run_dir}"

  if [[ "${selector}" == "all" ]]; then
    ids="$(jq -r '.scenes[].id' "${SCRIPT_DIR}/${SCENES_FILE}")"
  else
    [[ "${selector}" =~ ^[0-9]+$ ]] || die "gen expects scene id or all"
    ids="${selector}"
  fi

  local sid
  for sid in ${ids}; do
    run_one_scene "${sid}" "${run_id}"
  done

  save_workflow_state "${run_id}" "${remote_run_dir}" "${local_run_dir}"
  echo "Generation done. run_id=${run_id}"
}

cmd_pilot() {
  local start_id="${1:-1}"
  local end_id="${2:-10}"
  local run_id ids remote_run_dir local_run_dir

  [[ "${start_id}" =~ ^[0-9]+$ ]] || die "pilot start_id must be numeric"
  [[ "${end_id}" =~ ^[0-9]+$ ]] || die "pilot end_id must be numeric"
  (( start_id <= end_id )) || die "pilot start_id must be <= end_id"

  load_workflow_conf
  load_instance_state
  cmd_validate
  ensure_remote_i2v_script

  scp_to_remote "${SCRIPT_DIR}/${MASTER_IMAGES_DIR}" "${REMOTE_WORKDIR}/"

  run_id="$(date +"%Y%m%d_%H%M%S")_pilot_${start_id}_${end_id}"
  remote_run_dir="${REMOTE_RUNS_BASE}/full_workflow_${run_id}"
  local_run_dir="${SCRIPT_DIR}/${OUTPUT_DIR}/${run_id}"
  mkdir -p "${local_run_dir}"

  ids="$(jq -r --argjson s "${start_id}" --argjson e "${end_id}" '.scenes[] | select(.id >= $s and .id <= $e) | .id' "${SCRIPT_DIR}/${SCENES_FILE}")"
  [[ -n "${ids}" ]] || die "No scenes found in range ${start_id}-${end_id}"

  local sid
  for sid in ${ids}; do
    run_one_scene "${sid}" "${run_id}"
  done

  save_workflow_state "${run_id}" "${remote_run_dir}" "${local_run_dir}"
  echo "Pilot generation done. run_id=${run_id}"
}

resolve_run_dir() {
  local provided="${1:-}"
  if [[ -n "${provided}" ]]; then
    echo "${provided}"
    return 0
  fi
  if [[ -f "${WORKFLOW_STATE_FILE}" ]]; then
    jq -r '.remote_dir // empty' "${WORKFLOW_STATE_FILE}"
    return 0
  fi
  ssh_remote "ls -1dt ${REMOTE_RUNS_BASE}/full_workflow_* 2>/dev/null | head -n1" 2>/dev/null || true
}

cmd_stitch() {
  local output_name="final.mp4"
  local run_dir=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --output) shift; output_name="${1:?missing value for --output}" ;;
      --run-dir) shift; run_dir="${1:?missing value for --run-dir}" ;;
      *) die "Unknown stitch arg: $1" ;;
    esac
    shift || true
  done

  load_workflow_conf
  load_instance_state
  run_dir="$(resolve_run_dir "${run_dir}")"
  [[ -n "${run_dir}" ]] || die "Could not resolve run dir"

  local remote_final="${run_dir}/${output_name}"
  local remote_concat="${run_dir}/concat.txt"
  log "Stitching clips in ${run_dir}"
  ssh_remote "set -e; ls ${run_dir}/scene_*.mp4 >/dev/null 2>&1; \
    ls ${run_dir}/scene_*.mp4 | sort > ${remote_concat}; \
    sed -i \"s|^|file '|; s|\$|'|\" ${remote_concat}; \
    ffmpeg -y -f concat -safe 0 -i ${remote_concat} -c copy ${remote_final} || \
    ffmpeg -y -f concat -safe 0 -i ${remote_concat} -c:v libx264 -crf 18 -preset medium ${remote_final}; \
    test -f ${remote_final}"

  mkdir -p "${SCRIPT_DIR}/${OUTPUT_DIR}"
  scp_from_remote "${remote_final}" "${SCRIPT_DIR}/${OUTPUT_DIR}/${output_name}"
  echo "Stitched file copied to ${OUTPUT_DIR}/${output_name}"
}

cmd_status() {
  load_workflow_conf
  load_instance_state

  echo "Workflow state file: ${WORKFLOW_STATE_FILE}"
  if [[ -f "${WORKFLOW_STATE_FILE}" ]]; then
    cat "${WORKFLOW_STATE_FILE}"
  else
    echo "No workflow state yet."
  fi

  if [[ -f "${SCRIPT_DIR}/${SCENES_FILE}" ]]; then
    local total
    total="$(jq -r '.scenes | length' "${SCRIPT_DIR}/${SCENES_FILE}")"
    echo "Scenes defined: ${total}"
  fi

  local latest
  latest="$(ssh_remote "ls -1dt ${REMOTE_RUNS_BASE}/full_workflow_* 2>/dev/null | head -n1" 2>/dev/null || true)"
  if [[ -n "${latest}" ]]; then
    echo "Latest remote run: ${latest}"
    ssh_remote "ls -1 ${latest}/scene_*.mp4 2>/dev/null | wc -l | awk '{print \"Remote clips:\", \$1}'"
    ssh_remote "test -f ${latest}/final.mp4 && echo 'Remote final: present' || echo 'Remote final: missing'"
  else
    echo "No remote runs yet (or remote currently unreachable)."
  fi
}

usage() {
  cat <<'EOF'
Usage:
  ./video_script_full_workflow.sh <command> [args]

Commands:
  init                            create workflow.conf/scenes.json scaffold
  validate                        validate config, assets, state, and remote readiness
  gen <scene_id|all>              generate one or all scenes via remote I2V
  pilot [start_id] [end_id]       generate pilot range (default 1..10)
  stitch [--output FILE]          stitch generated clips on remote and copy final local
  status                          show workflow progress and latest run status

Examples:
  ./video_script_full_workflow.sh init
  ./video_script_full_workflow.sh validate
  ./video_script_full_workflow.sh gen 1
  ./video_script_full_workflow.sh gen all
  ./video_script_full_workflow.sh pilot
  ./video_script_full_workflow.sh pilot 1 10
  ./video_script_full_workflow.sh stitch --output final_full.mp4

Environment:
  BLUEPRINT_FILE=/abs/path/to/blueprint.txt
  WORKFLOW_CONF=/abs/path/to/workflow.conf
EOF
}

main() {
  local cmd="${1:-help}"
  shift || true
  case "${cmd}" in
    init) cmd_init "$@" ;;
    validate) cmd_validate "$@" ;;
    gen) cmd_gen "$@" ;;
    pilot) cmd_pilot "$@" ;;
    stitch) cmd_stitch "$@" ;;
    status) cmd_status "$@" ;;
    help|*) usage ;;
  esac
}

main "$@"
