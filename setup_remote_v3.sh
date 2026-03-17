#!/usr/bin/env bash
# setup_remote_v3.sh – runs ON the vast.ai instance
#
# Stacks:
#   text  → Ollama + Open WebUI       (unchanged from v2)
#   image → Diffusers SDXL + Gradio   (unchanged from v2)
#   video      → Wan2.1-T2V-14B-Diffusers + Gradio  (base T2V)
#   video_lora → Wan2.1-T2V-14B-Diffusers + Gradio  (LoRA-aware T2V)
#   video_i2v  → Wan2.1-I2V-14B-720P-Diffusers CLI backend
#
# Video: NO manual config needed. Setup installs everything and the Gradio UI
# uses WanPipeline directly in-process (model stays loaded in VRAM).
#
set -euo pipefail

STACK_TYPE="${STACK_TYPE:-text}"
STACK_MODEL="${STACK_MODEL:-}"
STACK_MODEL_FILE_HINT="${STACK_MODEL_FILE_HINT:-}"
STACK_TEMPLATE="${STACK_TEMPLATE:-}"
SERVICE_PORT="${SERVICE_PORT:-}"
PULL_MODEL="${PULL_MODEL:-1}"
HF_TOKEN="${HF_TOKEN:-${HUGGINGFACE_HUB_TOKEN:-}}"
FORCE_MODEL_REINSTALL="${FORCE_MODEL_REINSTALL:-0}"
IMAGE_APP_SOURCE="${IMAGE_APP_SOURCE:-}"
IMAGE_LORAS_JSON="${IMAGE_LORAS_JSON:-[]}"
if [[ -n "${HF_TOKEN}" ]]; then
  # huggingface_hub honors HF_TOKEN; keep both names for compatibility.
  export HF_TOKEN
  export HUGGINGFACE_HUB_TOKEN="${HF_TOKEN}"
fi

BIND_ADDR="127.0.0.1"
LOG_DIR="/var/log/stack"
ONSTART="/onstart.sh"

WEBUI_PORT="${WEBUI_PORT:-8080}"
OLLAMA_PORT="${OLLAMA_PORT:-11434}"
TEXT_PORT="${TEXT_PORT:-8080}"
IMAGE_PORT="${IMAGE_PORT:-7860}"
VIDEO_PORT="${VIDEO_PORT:-7861}"
VIDEO_LORA_PORT="${VIDEO_LORA_PORT:-7862}"
TEXT_PRO_PORT="${TEXT_PRO_PORT:-8081}"
COMFYUI_PORT="${COMFYUI_PORT:-7867}"

TEXT_DEFAULT_MODEL="cesarsal1nas/Huihui-Qwen3.5-35B-A3B-abliterated-Q4_K_M-GGUF"
TEXT_PRO_DEFAULT_MODEL="lmstudio-community/Llama-4-Scout-17B-16E-Instruct-GGUF"
IMAGE_DEFAULT_MODEL="stabilityai/stable-diffusion-xl-base-1.0"
IMAGE_PROMPT_DEFAULT_MODEL="black-forest-labs/FLUX.2-dev"
VIDEO_DEFAULT_MODEL="Wan-AI/Wan2.1-T2V-14B-Diffusers"
VIDEO_LORA_DEFAULT_MODEL="Wan-AI/Wan2.1-T2V-14B-Diffusers"
VIDEO_I2V_DEFAULT_MODEL="Wan-AI/Wan2.1-I2V-14B-720P-Diffusers"
COMFYUI_DEFAULT_MODEL="black-forest-labs/FLUX.2-dev"

WEBUI_DIR="/opt/open-webui"
WEBUI_VENV="${WEBUI_DIR}/venv"
LLAMA_CPP_DIR="/opt/llama.cpp"
LLAMA_CPP_BUILD_DIR="${LLAMA_CPP_DIR}/build"
LLAMA_SERVER_BIN="${LLAMA_CPP_BUILD_DIR}/bin/llama-server"
MODEL_DIR_BASE="/opt/models"
APP_DIR="/opt/generative-ui"
APP_VENV="${APP_DIR}/venv"
VIDEO_DIR="/opt/video-studio"
VIDEO_VENV="${VIDEO_DIR}/venv"
IMAGE_MODEL_DIR="${MODEL_DIR_BASE}/image/model"
IMAGE_PROMPT_MODEL_DIR="${MODEL_DIR_BASE}/image_prompt/model"
VIDEO_MODEL_DIR="${MODEL_DIR_BASE}/video/model"
VIDEO_LORA_MODEL_DIR="${MODEL_DIR_BASE}/video_lora/model"
VIDEO_I2V_MODEL_DIR="${MODEL_DIR_BASE}/video_i2v/model"
COMFYUI_DIR="/opt/comfyui"
COMFYUI_VENV="${COMFYUI_DIR}/venv"
COMFYUI_MODEL_DIR="${MODEL_DIR_BASE}/comfyui/model"

log() { echo "[$(date '+%H:%M:%S')] $*"; }
mkdir -p "${LOG_DIR}"
LOCK_DIR="/tmp/setup_remote_v3.lock"
LOCK_PID_FILE="${LOCK_DIR}/pid"
LOCK_STACK_FILE="${LOCK_DIR}/stack"
LOCK_STARTED_FILE="${LOCK_DIR}/started_at"
ACTIVE_CHILD_PID=""

cleanup_children() {
  local pid="${ACTIVE_CHILD_PID:-}"
  if [[ -n "${pid}" ]] && kill -0 "${pid}" >/dev/null 2>&1; then
    kill -TERM "${pid}" >/dev/null 2>&1 || true
    pkill -TERM -P "${pid}" >/dev/null 2>&1 || true
    sleep 1
    kill -KILL "${pid}" >/dev/null 2>&1 || true
    pkill -KILL -P "${pid}" >/dev/null 2>&1 || true
  fi
  pkill -TERM -P "$$" >/dev/null 2>&1 || true
}

release_lock() {
  local owner_pid=""
  if [[ -f "${LOCK_PID_FILE}" ]]; then
    owner_pid="$(cat "${LOCK_PID_FILE}" 2>/dev/null || true)"
  fi
  if [[ -z "${owner_pid}" || "${owner_pid}" == "$$" ]]; then
    rm -rf "${LOCK_DIR}" 2>/dev/null || true
  fi
}

write_lock_metadata() {
  printf '%s\n' "$$" > "${LOCK_PID_FILE}"
  printf '%s\n' "${STACK_TYPE}" > "${LOCK_STACK_FILE}"
  date -u +%Y-%m-%dT%H:%M:%SZ > "${LOCK_STARTED_FILE}"
}

clear_stale_lock_if_needed() {
  local owner_pid="" owner_stack="" started_at=""
  local live_setup_pid=""
  [[ -d "${LOCK_DIR}" ]] || return 1

  if [[ -f "${LOCK_PID_FILE}" ]]; then
    owner_pid="$(cat "${LOCK_PID_FILE}" 2>/dev/null || true)"
  fi
  if [[ -f "${LOCK_STACK_FILE}" ]]; then
    owner_stack="$(cat "${LOCK_STACK_FILE}" 2>/dev/null || true)"
  fi
  if [[ -f "${LOCK_STARTED_FILE}" ]]; then
    started_at="$(cat "${LOCK_STARTED_FILE}" 2>/dev/null || true)"
  fi

  if [[ -n "${owner_pid}" ]] && kill -0 "${owner_pid}" >/dev/null 2>&1; then
    return 1
  fi
  if [[ -z "${owner_pid}" ]]; then
    live_setup_pid="$(pgrep -f '/root/setup_remote.sh' 2>/dev/null | grep -vx "$$" | head -n 1 || true)"
    if [[ -n "${live_setup_pid}" ]]; then
      return 1
    fi
  fi

  log "Removing stale setup lock${owner_stack:+ for ${owner_stack}}${owner_pid:+ (pid ${owner_pid})}${started_at:+ from ${started_at}}..."
  rm -rf "${LOCK_DIR}" 2>/dev/null || true
  return 0
}

acquire_lock() {
  local waited=0 max_wait=300
  while ! mkdir "${LOCK_DIR}" 2>/dev/null; do
    if clear_stale_lock_if_needed; then
      continue
    fi
    if (( waited == 0 )); then
      local owner_pid="" owner_stack="" started_at=""
      [[ -f "${LOCK_PID_FILE}" ]] && owner_pid="$(cat "${LOCK_PID_FILE}" 2>/dev/null || true)"
      [[ -f "${LOCK_STACK_FILE}" ]] && owner_stack="$(cat "${LOCK_STACK_FILE}" 2>/dev/null || true)"
      [[ -f "${LOCK_STARTED_FILE}" ]] && started_at="$(cat "${LOCK_STARTED_FILE}" 2>/dev/null || true)"
      log "Another setup is running${owner_stack:+ for ${owner_stack}}${owner_pid:+ (pid ${owner_pid})}${started_at:+ since ${started_at}}, waiting for lock..."
    fi
    sleep 5
    waited=$((waited + 5))
    if (( waited >= max_wait )); then
      echo "✗ Another setup still holds lock after ${max_wait}s. Abort." >&2
      exit 1
    fi
  done
  write_lock_metadata
  trap 'cleanup_children; release_lock' EXIT INT TERM
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "✗ Missing required command: $1" >&2
    exit 1
  }
}

run_with_heartbeat() {
  local label="$1"
  shift
  local start_ts now elapsed
  start_ts="$(date +%s)"
  "$@" &
  local cmd_pid=$!
  ACTIVE_CHILD_PID="${cmd_pid}"
  while kill -0 "${cmd_pid}" >/dev/null 2>&1; do
    sleep 20
    if kill -0 "${cmd_pid}" >/dev/null 2>&1; then
      now="$(date +%s)"
      elapsed=$(( now - start_ts ))
      log "${label} still running (${elapsed}s)..."
    fi
  done
  wait "${cmd_pid}"
  local rc=$?
  ACTIVE_CHILD_PID=""
  return "${rc}"
}

# GPU detection - returns GPU name
get_gpu_name() {
  nvidia-smi --query-gpu=gpu_name --format=csv,noheader 2>/dev/null | head -1 || echo ""
}

# Check if GPU is H100 or better (H100, H200, B200, etc.)
is_h100_or_better() {
  local gpu_name
  gpu_name=$(get_gpu_name)
  
  # Check for H100, H200, B200, or any GPU with higher compute capability
  if [[ "$gpu_name" =~ H100|H200|B200|B100|GH200 ]]; then
    log "Detected high-end GPU: ${gpu_name}"
    return 0
  fi
  
  # Also check via compute capability (H100 = sm_90)
  local compute_cap
  compute_cap=$(nvidia-smi --query-gpu=compute_cap --format=csv,noheader 2>/dev/null | head -1 | tr '.' '')
  if [[ -n "$compute_cap" ]] && [[ "$compute_cap" -ge 90 ]]; then
    log "Detected GPU with compute capability ${compute_cap} (H100+ class)"
    return 0
  fi
  
  log "GPU ${gpu_name} is not H100 or better"
  return 1
}

# Require H100+ GPU for text_pro stack
require_h100_gpu() {
  if ! is_h100_or_better; then
    echo "✗ text_pro stack requires H100 or better GPU" >&2
    echo "✗ Current GPU: $(get_gpu_name)" >&2
    echo "✗ Please rent a different instance or use the regular 'text' stack" >&2
    return 1
  fi
  return 0
}

# ── Shared ────────────────────────────────────────────────────────────────

install_deps_common() {
  log "Installing base dependencies..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y -qq
  apt-get install -y -qq \
    ca-certificates \
    curl wget git \
    python3 python3-pip python3-venv \
    build-essential libssl-dev libffi-dev \
    net-tools lsof procps ffmpeg zstd cmake ninja-build \
    apt-transport-https gnupg lsb-release

  # Install Docker if not present (for extracting prebuilt llama-server)
  if ! command -v docker &>/dev/null; then
    log "Installing Docker..."
    if [[ ! -f /etc/apt/sources.list.d/docker.list ]]; then
      curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/trusted.gpg.d/docker.gpg >/dev/null 2>&1 || true
      echo "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" > /etc/apt/sources.list.d/docker.list
    fi
    apt-get update -qq >/dev/null 2>&1 || true
    apt-get install -y -qq docker-ce docker-ce-cli containerd.io >/dev/null 2>&1 || {
      log "⚠ Docker installation failed, continuing without Docker"
    }
  fi

  # Verify core tools required by this script are available.
  need_cmd curl
  need_cmd python3
  need_cmd ffmpeg
  need_cmd zstd
  need_cmd cmake
  log "Base dependencies installed."
}

wait_for_port() {
  local host="$1" port="$2" max="${3:-30}" secs="${4:-2}"
  log "Waiting for ${host}:${port}..."
  for i in $(seq 1 "${max}"); do
    if curl -sf "http://${host}:${port}" &>/dev/null 2>&1 \
        || curl -sf "http://${host}:${port}/api/tags" &>/dev/null 2>&1 \
        || curl -sf "http://${host}:${port}/v1/models" &>/dev/null 2>&1 \
        || curl -sf "http://${host}:${port}/health" &>/dev/null 2>&1; then
      log "${host}:${port} ready."; return 0
    fi
    printf '.'; sleep "${secs}"
  done
  echo; log "WARNING: ${host}:${port} not responding – continuing."
}

ensure_merged_model_path() {
  local model_path="$1"
  if [[ "$model_path" =~ ^(.+)\.part([0-9]+)of([0-9]+)$ ]]; then
    local merged_path="${BASH_REMATCH[1]}"
    local total_parts="${BASH_REMATCH[3]}"
    local idx part_path
    if [[ -f "${merged_path}" ]]; then
      echo "${merged_path}"
      return 0
    fi
    log "Merging ${total_parts} model parts into ${merged_path}..."
    part_path="${merged_path}.part1of${total_parts}"
    if [[ ! -f "${part_path}" ]]; then
      echo "✗ Missing model part: ${part_path}" >&2
      return 1
    fi
    mv "${part_path}" "${merged_path}"
    for idx in $(seq 2 "${total_parts}"); do
      part_path="${merged_path}.part${idx}of${total_parts}"
      if [[ ! -f "${part_path}" ]]; then
        echo "✗ Missing model part: ${part_path}" >&2
        return 1
      fi
      log "Merge ${idx}/${total_parts}: ${part_path}"
      cat "${part_path}" >> "${merged_path}"
      rm -f "${part_path}" >/dev/null 2>&1 || true
    done
    echo "${merged_path}"
    return 0
  fi
  echo "${model_path}"
}

# ── llama.cpp Installation - Optimized ────────────────────────────────────
# Priority: 1) System package 2) Prebuilt binary 3) Source build (fallback)

install_llama_cpp() {
  local existing_bin=""
  local USE_PREBUILT="${USE_PREBUILT_LLAMA:-1}"
  local FORCE_SOURCE="${FORCE_SOURCE_BUILD:-0}"
  
  # Priority 1: Check for existing system-wide installation
  existing_bin="$(command -v llama-server 2>/dev/null || true)"
  if [[ -n "${existing_bin}" && -x "${existing_bin}" && "${FORCE_SOURCE}" != "1" ]]; then
    LLAMA_SERVER_BIN="${existing_bin}"
    log "✓ Using system llama-server: ${LLAMA_SERVER_BIN}"
    ln -sf "${LLAMA_SERVER_BIN}" /usr/local/bin/llama-server 2>/dev/null || true
    return 0
  fi
  
  # Priority 2: Check for existing build in standard location
  if [[ -x "${LLAMA_SERVER_BIN}" && "${FORCE_SOURCE}" != "1" ]]; then
    log "✓ Using existing llama.cpp build: ${LLAMA_SERVER_BIN}"
    ln -sf "${LLAMA_SERVER_BIN}" /usr/local/bin/llama-server
    return 0
  fi
  
  # Priority 3: Try prebuilt binary from llama.cpp releases
  if [[ "${USE_PREBUILT}" == "1" && "${FORCE_SOURCE}" != "1" ]]; then
    if _try_install_prebuilt_llama; then
      log "✓ Using prebuilt llama-server binary"
      return 0
    fi
    log "⚠ Prebuilt binary not available, falling back to source build..."
  fi
  
  # Priority 4: Source build (fallback)
  log "Building llama.cpp from source (CUDA)..."
  _build_llama_cpp_from_source || {
    echo "✗ llama.cpp build failed." >&2
    return 1
  }
  
  ln -sf "${LLAMA_SERVER_BIN}" /usr/local/bin/llama-server
  log "✓ llama.cpp ready: ${LLAMA_SERVER_BIN}"
  return 0
}

_try_install_prebuilt_llama() {
  # Try to obtain prebuilt llama-server binary
  # This avoids the ~5-10 minute CUDA build on every instance start
  #
  # Strategy:
  # 1. Extract from official llama.cpp Docker image (fastest, has CUDA)
  # 2. Fall back to source build if Docker method fails

  local target_dir="${LLAMA_CPP_DIR}"
  local bin_target="${target_dir}/llama-server"

  mkdir -p "${target_dir}"

  # Check if we already have a prebuilt binary
  if [[ -x "${bin_target}" ]]; then
    LLAMA_SERVER_BIN="${bin_target}"
    log "✓ Using existing prebuilt binary: ${LLAMA_SERVER_BIN}"
    return 0
  fi

  # ── Option 1: Extract from official llama.cpp Docker image ───────────────
  # The official image contains a CUDA-enabled build for Linux
  # Image: ghcr.io/ggml-org/llama.cpp:server (or latest)
  
  log "Attempting to extract llama-server from official Docker image..."

  # Check if docker is available
  if command -v docker &>/dev/null; then
    local docker_image="ghcr.io/ggml-org/llama.cpp:server"
    local container_name="llama_extract_$$"
    
    log "Using Docker image: ${docker_image}"
    
    # Pull the image
    if docker pull "${docker_image}" >/dev/null 2>&1; then
      # Create a temporary container to extract the binary
      if docker create --name "${container_name}" "${docker_image}" >/dev/null 2>&1; then
        # Find where llama-server is located in the image
        # Common locations: /usr/bin/llama-server, /opt/llama.cpp/build/bin/llama-server
        local image_bin_path=""
        
        # Try to find the binary location
        image_bin_path=$(docker run --rm --entrypoint /bin/sh "${docker_image}" -c \
          "find /usr /opt /app -name 'llama-server' -type f 2>/dev/null | head -1" 2>/dev/null || echo "")
        
        if [[ -n "${image_bin_path}" ]]; then
          log "Found llama-server in image at: ${image_bin_path}"
          
          # Extract the binary
          if docker cp "${container_name}:${image_bin_path}" "${bin_target}" 2>/dev/null; then
            chmod +x "${bin_target}"
            docker rm -f "${container_name}" >/dev/null 2>&1 || true
            
            # Also try to extract CUDA libraries if present
            local cuda_lib_path
            cuda_lib_path=$(docker run --rm --entrypoint /bin/sh "${docker_image}" -c \
              "find /usr /opt /app -name 'libcu*.so*' -o -name 'libcublas*.so*' 2>/dev/null | head -5" 2>/dev/null || echo "")
            
            if [[ -n "${cuda_lib_path}" ]]; then
              log "Extracting CUDA libraries..."
              docker cp "${container_name}:${cuda_lib_path}" "${target_dir}/" 2>/dev/null || true
            fi
            
            docker rm -f "${container_name}" >/dev/null 2>&1 || true
            LLAMA_SERVER_BIN="${bin_target}"
            log "✓ Successfully extracted llama-server from Docker image: ${LLAMA_SERVER_BIN}"
            return 0
          fi
        fi
        docker rm -f "${container_name}" >/dev/null 2>&1 || true
      fi
    fi
    log "⚠ Docker extraction failed"
  else
    log "⚠ Docker not available on this system"
  fi

  # No suitable prebuilt binary found - fall back to source build
  log "⚠ No suitable prebuilt binary found, will build from source"
  return 1
}

_build_llama_cpp_from_source() {
  # Source build with optimizations:
  # - Minimal clone (shallow, no tags)
  # - Only build llama-server (not all tools)
  # - Release build with CUDA
  # - Clean up build artifacts after success
  # - Heartbeat during long build to prevent SSH timeout

  log "Cloning llama.cpp (shallow, minimal)..."

  # Use minimal clone: depth=1, no tags, single branch
  if [[ ! -d "${LLAMA_CPP_DIR}/.git" ]]; then
    git clone --depth 1 --no-tags --single-branch \
      https://github.com/ggml-org/llama.cpp.git "${LLAMA_CPP_DIR}" 2>/dev/null || {
      log "✗ Failed to clone llama.cpp"
      return 1
    }
  else
    log "llama.cpp source already present"
  fi

  # Check if already built
  if [[ -x "${LLAMA_SERVER_BIN}" ]]; then
    log "llama.cpp already built at ${LLAMA_SERVER_BIN}"
    return 0
  fi

  log "Building llama-server with CUDA (this may take 5-10 minutes)..."

  # Install build dependencies if missing
  if ! command -v cmake &>/dev/null; then
    log "Installing cmake..."
    apt-get update -qq && apt-get install -y -qq cmake >/dev/null 2>&1 || true
  fi

  # Configure with minimal options
  # Only build llama-server, skip tests and examples
  if [[ ! -f "${LLAMA_CPP_BUILD_DIR}/CMakeCache.txt" ]]; then
    cmake -S "${LLAMA_CPP_DIR}" -B "${LLAMA_CPP_BUILD_DIR}" \
      -DGGML_CUDA=ON \
      -DGGML_NATIVE=OFF \
      -DCMAKE_BUILD_TYPE=Release \
      -DBUILD_SHARED_LIBS=OFF \
      -DGGML_BUILD_TESTS=OFF \
      -DGGML_BUILD_EXAMPLES=OFF \
      -DGGML_BUILD_SERVER=ON \
      -DCMAKE_INSTALL_PREFIX="${LLAMA_CPP_BUILD_DIR}" \
      2>&1 | tee -a "${LOG_DIR}/llama_build.log" || {
      log "✗ CMake configuration failed"
      return 1
    }
  fi

  # Build only llama-server target with progress output
  # Use tee to capture output and keep connection alive
  log "Starting compilation (watch ${LOG_DIR}/llama_build.log for details)..."
  
  local build_start
  build_start=$(date +%s)
  
  cmake --build "${LLAMA_CPP_BUILD_DIR}" \
    --config Release \
    --target llama-server \
    -j"$(nproc)" \
    2>&1 | tee -a "${LOG_DIR}/llama_build.log" || {
    log "✗ Build failed"
    return 1
  }

  local build_end
  build_end=$(date +%s)
  local build_duration=$((build_end - build_start))
  log "Build completed in ${build_duration}s"

  # Verify build success
  if [[ ! -x "${LLAMA_SERVER_BIN}" ]]; then
    log "✗ llama-server binary not found after build"
    return 1
  fi

  # Optional: Clean build directory to save space
  # Keep only the binary, remove object files
  if [[ -d "${LLAMA_CPP_BUILD_DIR}/CMakeFiles" ]]; then
    log "Cleaning build artifacts to save space..."
    find "${LLAMA_CPP_BUILD_DIR}" -name "*.o" -delete 2>/dev/null || true
    rm -rf "${LLAMA_CPP_BUILD_DIR}/CMakeFiles" 2>/dev/null || true
    rm -f "${LLAMA_CPP_BUILD_DIR}/CMakeCache.txt" 2>/dev/null || true
  fi

  log "✓ llama-server built successfully"
  return 0
}

install_hf_hub() {
  if python3 -c "import huggingface_hub" >/dev/null 2>&1; then
    log "huggingface_hub already installed."
    return 0
  fi
  python3 -m pip install -q --root-user-action=ignore huggingface_hub
}

resolve_gguf_model_path() {
  local repo="$1"
  local file_hint="$2"
  local stack_key="$3"
  local model_dir="${MODEL_DIR_BASE}/${stack_key}"
  mkdir -p "${model_dir}"

  python3 -u - "$repo" "$file_hint" "$model_dir" <<'PY'
import os
import sys
import shutil
import re
from huggingface_hub import HfApi, hf_hub_download

repo, file_hint, model_dir = sys.argv[1:4]
token = os.environ.get("HF_TOKEN") or os.environ.get("HUGGINGFACE_HUB_TOKEN") or None
force_reinstall = os.environ.get("FORCE_MODEL_REINSTALL", "0").lower() in {"1", "true", "yes", "on"}
print(f"[hf] token {'detected' if token else 'missing'} for repo {repo}", file=sys.stderr, flush=True)
api = HfApi(token=token)

def is_candidate(path: str) -> bool:
    name = os.path.basename(path).lower()
    if "mmproj" in name:
        return False
    return name.endswith(".gguf") or ".gguf.part" in name

files = [f for f in api.list_repo_files(repo) if is_candidate(f)]
if not files:
    raise SystemExit(f"No GGUF files found in repo: {repo}")

def base(path: str) -> str:
    return os.path.basename(path)

selected = []
if file_hint:
    if file_hint.lower().endswith(".gguf"):
        selected = [f for f in files if f == file_hint or base(f) == file_hint]
    else:
        selected = [f for f in files if base(f).startswith(file_hint)]
else:
    selected = sorted(files)

selected = sorted(set(selected))
if not selected:
    raise SystemExit(f"No GGUF files matching '{file_hint}' found in repo: {repo}")

def sort_key(path: str):
    name = base(path)
    m_split = re.search(r"\.part(\d+)of(\d+)$", name, re.IGNORECASE)
    if m_split:
        return (0, int(m_split.group(1)), name)
    m_shard = re.search(r"-(\d+)-of-(\d+)\.gguf$", name, re.IGNORECASE)
    if m_shard:
        return (0, int(m_shard.group(1)), name)
    return (1, 0, name)

selected = sorted(selected, key=sort_key)
primary = selected[0]
multipart_matches = [
    re.search(r"\.part(\d+)of(\d+)$", base(path), re.IGNORECASE)
    for path in selected
]
shard_matches = [
    re.search(r"-(\d+)-of-(\d+)\.gguf$", base(path), re.IGNORECASE)
    for path in selected
]
split_style = None
merged_basename = None
if bool(selected) and all(multipart_matches):
    split_style = "part"
    merged_basename = re.sub(r"\.part1of\d+$", "", base(selected[0]), flags=re.IGNORECASE)

existing_ggufs = []
for root, _, filenames in os.walk(model_dir):
    for name in filenames:
        lower_name = name.lower()
        if lower_name.endswith(".gguf") or ".gguf.part" in lower_name:
            existing_ggufs.append(os.path.join(root, name))

selected_basenames = {base(path) for path in selected}
if merged_basename:
    selected_basenames.add(merged_basename)
existing_basenames = {os.path.basename(path) for path in existing_ggufs}
existing_selected_parts = all(
    os.path.exists(os.path.join(model_dir, rel_path))
    for rel_path in selected
)
merged_exists = bool(merged_basename) and os.path.exists(os.path.join(model_dir, merged_basename))
acceptable_existing = False
if existing_basenames:
    if merged_basename:
        acceptable_existing = existing_basenames.issubset(selected_basenames) and (
            merged_basename in existing_basenames or existing_selected_parts
        )
    else:
        acceptable_existing = existing_basenames.issubset(selected_basenames) and existing_selected_parts

needs_cleanup = bool(existing_basenames) and not acceptable_existing

if force_reinstall:
    if needs_cleanup:
        pass
    elif acceptable_existing:
        if split_style == "part" and existing_selected_parts and not merged_exists:
            print("[hf] desired model parts already exist; skipping re-download and rebuilding merged gguf", file=sys.stderr, flush=True)
        else:
            print("[hf] desired model files already exist; skipping forced re-download", file=sys.stderr, flush=True)
    elif existing_ggufs:
        needs_cleanup = True

if needs_cleanup and os.path.isdir(model_dir):
    print(f"[hf] removing old model dir {model_dir}", file=sys.stderr, flush=True)
    shutil.rmtree(model_dir, ignore_errors=True)
    os.makedirs(model_dir, exist_ok=True)
else:
    # Cleanup individual ggufs that don't match the new expected ones
    for old_gguf in existing_ggufs:
        base_name = os.path.basename(old_gguf)
        is_expected = False
        for expected in selected_basenames:
            if base_name == expected:
                is_expected = True
                break
        if not is_expected and base_name != merged_basename:
            print(f"[hf] removing old model file {old_gguf}", file=sys.stderr, flush=True)
            try:
                os.remove(old_gguf)
            except OSError:
                pass

primary_path = ""
selected_for_download = list(selected)
if split_style == "part" and merged_basename:
    merged_path = os.path.join(model_dir, merged_basename)
    if os.path.exists(merged_path):
        print(f"[hf] already have merged {merged_basename}", file=sys.stderr, flush=True)
        primary_path = merged_path
        selected_for_download = []

total = len(selected)
for idx, rel_path in enumerate(selected_for_download, start=1):
    target_path = os.path.join(model_dir, rel_path)
    if os.path.exists(target_path):
        print(f"[hf] already have {idx}/{total} {rel_path}", file=sys.stderr, flush=True)
        local_path = target_path
    else:
        print(f"[hf] downloading {idx}/{total} {rel_path}", file=sys.stderr, flush=True)
        local_path = hf_hub_download(
            repo_id=repo,
            filename=rel_path,
            local_dir=model_dir,
            token=token,
            force_download=False,
        )
    if rel_path == primary:
        primary_path = local_path

if split_style == "part" and merged_basename:
    merged_path = os.path.join(model_dir, merged_basename)
    if not os.path.exists(merged_path):
        print(f"[hf] combining {len(selected)} parts into {merged_basename}", file=sys.stderr, flush=True)
        first_part = os.path.join(model_dir, selected[0])
        if not os.path.exists(first_part):
            raise SystemExit(f"Missing first model part for merge: {first_part}")
        if not os.path.exists(merged_path):
            os.replace(first_part, merged_path)
        with open(merged_path, "ab") as out:
            for idx, rel_path in enumerate(selected[1:], start=2):
                part_path = os.path.join(model_dir, rel_path)
                print(f"[hf] merge {idx}/{len(selected)} {base(rel_path)}", file=sys.stderr, flush=True)
                with open(part_path, "rb") as part_file:
                    shutil.copyfileobj(part_file, out, length=16 * 1024 * 1024)
                os.remove(part_path)
    else:
        print(f"[hf] already have merged {merged_basename}", file=sys.stderr, flush=True)
    primary_path = merged_path
elif not primary_path:
    primary_path = os.path.join(model_dir, primary)

print(primary_path)
PY
}

start_llama_server() {
  local stack_key="$1"
  local label="$2"
  local port="$3"
  local model_path="$4"
  local ctx_size="${5:-8192}"
  model_path="$(ensure_merged_model_path "${model_path}")"

  if pgrep -af "llama-server.*--port ${port}" >/dev/null 2>&1 || \
     curl -sf "http://${BIND_ADDR}:${port}" >/dev/null 2>&1 || \
     curl -sf "http://${BIND_ADDR}:${port}/health" >/dev/null 2>&1 || \
     curl -sf "http://${BIND_ADDR}:${port}/v1/models" >/dev/null 2>&1; then
    log "${label} already running on ${port}."
    return 0
  fi

  log "Starting ${label} on ${BIND_ADDR}:${port}..."
  nohup stdbuf -oL -eL "${LLAMA_SERVER_BIN}" \
    -m "${model_path}" \
    --host "${BIND_ADDR}" \
    --port "${port}" \
    -c "${ctx_size}" \
    -ngl 999 \
    >"${LOG_DIR}/${stack_key}.log" 2>&1 &
  disown
  wait_for_port "${BIND_ADDR}" "${port}" 60 2
}

write_onstart_llama_server() {
  local stack_key="$1"
  local label="$2"
  local port="$3"
  local model_path="$4"
  local ctx_size="${5:-8192}"
  cat > "${ONSTART}" <<EOF
#!/usr/bin/env bash
set -euo pipefail
LOG_DIR="/var/log/stack"
BIND_ADDR="127.0.0.1"
LLAMA_SERVER_BIN="${LLAMA_SERVER_BIN}"
MODEL_PATH="${model_path}"
PORT="${port}"
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
log "=== Starting ${label} ==="
ensure_model_path

if ! pgrep -af "llama-server.*--port \${PORT}" >/dev/null 2>&1; then
  log "Starting llama-server on \${BIND_ADDR}:\${PORT}..."
  nohup stdbuf -oL -eL "\${LLAMA_SERVER_BIN}" \
    -m "\${MODEL_PATH}" \
    --host "\${BIND_ADDR}" \
    --port "\${PORT}" \
    -c "\${CTX_SIZE}" \
    -ngl 999 \
    >"\${LOG_DIR}/${stack_key}.log" 2>&1 &
  disown
fi

ready=0
for i in \$(seq 1 60); do
  if curl -sf "http://\${BIND_ADDR}:\${PORT}" >/dev/null 2>&1 || \
     curl -sf "http://\${BIND_ADDR}:\${PORT}/health" >/dev/null 2>&1 || \
     curl -sf "http://\${BIND_ADDR}:\${PORT}/v1/models" >/dev/null 2>&1; then
    log "${label} ready on port \${PORT}"
    ready=1
    break
  fi
  if (( i == 1 || i % 10 == 0 )); then
    log "${label} noch nicht bereit (\${i}s). Log: \${LOG_DIR}/${stack_key}.log"
  fi
  sleep 1
done

if (( ready == 1 )); then
  log "${label} started."
else
  log "${label} noch im Start. Pruefe ${LOG_DIR}/${stack_key}.log"
fi
EOF
  chmod +x "${ONSTART}"
  log "Created ${ONSTART} for ${stack_key} stack."
}

ollama_model_url() {
  python3 - "$1" <<'PY'
import sys
from urllib.parse import quote
model = sys.argv[1]
print("https://ollama.com/" + quote(model, safe="/"))
PY
}

check_ollama_library_model() {
  local model="$1"
  local url http_code
  url="$(ollama_model_url "$model")"
  http_code="$(curl -L -sS -o /dev/null -w '%{http_code}' --max-time 20 "$url" || true)"
  case "$http_code" in
    200) return 0 ;;
    404) return 1 ;;
    *) return 2 ;;
  esac
}

ensure_ollama_model_pullable() {
  local model="$1"
  local label="${2:-Ollama model}"
  local url
  url="$(ollama_model_url "$model")"
  log "Checking Ollama library entry for ${model}..."

  if check_ollama_library_model "$model"; then
    log "Ollama library entry found: ${url}"
    return 0
  fi

  local check_rc=$?
  if [[ $check_rc -eq 1 ]]; then
    echo "✗ ${label} '${model}' wurde nicht in der Ollama Library gefunden." >&2
    echo "✗ Geprüft: ${url}" >&2
    echo "✗ 'ollama pull' funktioniert nur für Modelle, die in der Ollama Library existieren." >&2
    echo "✗ Dieser Name sieht nach einem externen Repo aus. Für Hugging-Face-Modelle brauchst du GGUF/Modelfile + 'ollama create'." >&2
    return 1
  fi

  echo "✗ Konnte vor dem Pull nicht prüfen, ob '${model}' in der Ollama Library existiert." >&2
  echo "✗ Geprüft: ${url}" >&2
  echo "✗ Ursache ist wahrscheinlich Netzwerk/DNS/HTTP statt Ollama selbst. Pull wird abgebrochen." >&2
  return 1
}

# ── TEXT (same as v2) ─────────────────────────────────────────────────────

install_ollama() {
  command -v ollama &>/dev/null && { log "Ollama installed."; return; }
  if ! command -v zstd &>/dev/null; then
    log "zstd missing, installing (required by Ollama installer)..."
    apt-get update -y -qq
    apt-get install -y -qq zstd
  fi
  log "Installing Ollama..."
  curl -fsSL https://ollama.com/install.sh | sh
}

start_ollama() {
  if pgrep -f "ollama serve" &>/dev/null; then log "Ollama running."; return; fi
  log "Starting Ollama on ${BIND_ADDR}:${OLLAMA_PORT}..."
  OLLAMA_HOST="${BIND_ADDR}:${OLLAMA_PORT}" nohup ollama serve >"${LOG_DIR}/ollama.log" 2>&1 &
  disown
  wait_for_port "${BIND_ADDR}" "${OLLAMA_PORT}" 30 2
}

# ── TEXT PRO (H100+ only, separate Ollama instance) ──────────────────────

install_ollama_pro() {
  # Uses same Ollama installation, just different port
  command -v ollama &>/dev/null || install_ollama
  log "Ollama available for text_pro stack."
}

start_ollama_pro() {
  # Check if already running on text_pro port
  if pgrep -f "ollama.*${TEXT_PRO_PORT}" &>/dev/null || \
     curl -sf "http://${BIND_ADDR}:${TEXT_PRO_PORT}/api/tags" &>/dev/null 2>&1; then
    log "Ollama Pro already running on ${TEXT_PRO_PORT}."
    return 0
  fi
  
  log "Starting Ollama Pro on ${BIND_ADDR}:${TEXT_PRO_PORT}..."
  OLLAMA_HOST="${BIND_ADDR}:${TEXT_PRO_PORT}" nohup ollama serve >"${LOG_DIR}/ollama_pro.log" 2>&1 &
  disown
  wait_for_port "${BIND_ADDR}" "${TEXT_PRO_PORT}" 30 2
}

pull_ollama_pro_model() {
  [[ "${PULL_MODEL}" == "1" ]] || return
  ensure_ollama_model_pullable "${1}" "Ollama Pro model" || return 1
  log "Pulling Ollama Pro model: ${1} (this is a large model, may take a while)..."
  OLLAMA_HOST="${BIND_ADDR}:${TEXT_PRO_PORT}" ollama pull "${1}"
  log "Model pull done: ${1}"
}

write_onstart_text_pro() {
  local model_path="$1"
  local ctx_size="${2:-16384}"
  write_onstart_llama_server "text_pro" "TEXT_PRO llama.cpp" "${TEXT_PRO_PORT}" "${model_path}" "${ctx_size}"
}

install_open_webui() {
  [[ -f "${WEBUI_VENV}/bin/activate" ]] && \
    "${WEBUI_VENV}/bin/python" -m open_webui --help &>/dev/null 2>&1 && \
    { log "Open WebUI already installed."; return 0; }
  
  log "Installing Open WebUI..."
  mkdir -p "${WEBUI_DIR}"
  python3 -m venv "${WEBUI_VENV}"
  "${WEBUI_VENV}/bin/pip" install --upgrade pip -q
  
  # Check Python version for compatibility
  local py_version
  py_version=$("${WEBUI_VENV}/bin/python" -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')")
  log "Python version: ${py_version}"
  
  # Try to install open-webui, fallback to ollama-webui if it fails
  if "${WEBUI_VENV}/bin/pip" install open-webui -q 2>/dev/null; then
    log "Open WebUI installed successfully."
    return 0
  else
    log "open-webui installation failed, trying ollama-webui..."
    "${WEBUI_VENV}/bin/pip" uninstall open-webui -y -q 2>/dev/null || true
    if "${WEBUI_VENV}/bin/pip" install ollama-webui -q 2>/dev/null; then
      log "ollama-webui installed as fallback."
      return 0
    else
      log "WARNING: Neither open-webui nor ollama-webui could be installed."
      log "You can install manually later with: pip install open-webui"
      return 1
    fi
  fi
}

start_open_webui() {
  if pgrep -f "open.webui" &>/dev/null || pgrep -f "uvicorn.*open_webui" &>/dev/null || pgrep -f "ollama.webui" &>/dev/null; then 
    log "Open WebUI running."; 
    return
  fi
  
  # Determine which package is installed
  local webui_module="open_webui"
  if ! "${WEBUI_VENV}/bin/python" -m open_webui --help &>/dev/null 2>&1; then
    if "${WEBUI_VENV}/bin/python" -m ollama_webui --help &>/dev/null 2>&1; then
      webui_module="ollama_webui"
      log "Using ollama_webui module."
    else
      log "WARNING: No WebUI module found, trying to start anyway..."
    fi
  fi
  
  log "Starting Open WebUI on ${BIND_ADDR}:${WEBUI_PORT}..."
  OLLAMA_BASE_URL="http://${BIND_ADDR}:${OLLAMA_PORT}" \
  DATA_DIR="${WEBUI_DIR}/data" HOST="${BIND_ADDR}" PORT="${WEBUI_PORT}" \
    nohup "${WEBUI_VENV}/bin/python" -m "${webui_module}" serve >"${LOG_DIR}/webui.log" 2>&1 &
  disown
  wait_for_port "${BIND_ADDR}" "${WEBUI_PORT}" 40 5
}

pull_ollama_model() {
  [[ "${PULL_MODEL}" == "1" ]] || return
  ensure_ollama_model_pullable "${1}" "Ollama model" || return 1
  log "Pulling Ollama model: ${1}"
  OLLAMA_HOST="${BIND_ADDR}:${OLLAMA_PORT}" ollama pull "${1}"
  log "Model pull done: ${1}"
}

# ── IMAGE (same as v2) ───────────────────────────────────────────────────

install_image_env() {
  log "Preparing image python environment..."
  [[ -f "${APP_VENV}/bin/activate" ]] || {
    mkdir -p "${APP_DIR}"; python3 -m venv "${APP_VENV}"
  }

  log "Upgrading image pip..."
  run_with_heartbeat "Image pip upgrade" "${APP_VENV}/bin/pip" install --upgrade pip -q

  log "Installing image torch packages..."
  if ! run_with_heartbeat "Image torch install" \
    "${APP_VENV}/bin/pip" install torch torchvision torchaudio \
    --index-url https://download.pytorch.org/whl/cu121; then
    log "Falling back to default torch index for image stack..."
    run_with_heartbeat "Image torch install (fallback)" \
      "${APP_VENV}/bin/pip" install torch torchvision torchaudio
  fi

  log "Installing image diffusers/gradio packages..."
  run_with_heartbeat "Image python deps install" "${APP_VENV}/bin/pip" install \
    "diffusers>=0.32.0" transformers accelerate safetensors peft \
    huggingface_hub "gradio>=4.0.0" "imageio[ffmpeg]" pillow
  log "Image python environment ready."
}

install_image_prompt_env() {
  log "Preparing image_prompt python environment..."
  [[ -f "${APP_VENV}/bin/activate" ]] || {
    mkdir -p "${APP_DIR}"; python3 -m venv "${APP_VENV}"
  }

  log "Upgrading image_prompt pip..."
  run_with_heartbeat "Image pip upgrade" "${APP_VENV}/bin/pip" install --upgrade pip -q

  log "Installing image_prompt torch packages (CUDA 12.4)..."
  if ! run_with_heartbeat "Image torch install" \
    "${APP_VENV}/bin/pip" install torch torchvision torchaudio \
    --index-url https://download.pytorch.org/whl/cu124; then
    log "Falling back to CUDA 12.1 for image_prompt stack..."
    run_with_heartbeat "Image torch install (fallback)" \
      "${APP_VENV}/bin/pip" install torch torchvision torchaudio \
      --index-url https://download.pytorch.org/whl/cu121
  fi

  log "Installing image_prompt diffusers/gradio packages..."
  run_with_heartbeat "Image python deps install" "${APP_VENV}/bin/pip" install \
    "diffusers>=0.32.0" transformers accelerate safetensors peft \
    huggingface_hub "gradio>=4.0.0" "imageio[ffmpeg]" pillow sentencepiece protobuf \
    xformers einops
  log "Image python environment ready."
}

install_comfyui_env() {
  log "Preparing ComfyUI python environment..."
  mkdir -p "${COMFYUI_DIR}" "${MODEL_DIR_BASE}/loras"
  [[ -f "${COMFYUI_VENV}/bin/activate" ]] || python3 -m venv "${COMFYUI_VENV}"

  log "Upgrading ComfyUI pip..."
  run_with_heartbeat "ComfyUI pip upgrade" "${COMFYUI_VENV}/bin/pip" install --upgrade pip -q

  log "Installing ComfyUI torch packages (CUDA 12.4)..."
  if ! run_with_heartbeat "ComfyUI torch install" \
    "${COMFYUI_VENV}/bin/pip" install torch torchvision torchaudio \
    --index-url https://download.pytorch.org/whl/cu124; then
    log "Falling back to CUDA 12.1 for ComfyUI stack..."
    run_with_heartbeat "ComfyUI torch install (fallback)" \
      "${COMFYUI_VENV}/bin/pip" install torch torchvision torchaudio \
      --index-url https://download.pytorch.org/whl/cu121
  fi

  log "Installing ComfyUI and custom nodes dependencies..."
  run_with_heartbeat "ComfyUI python deps install" "${COMFYUI_VENV}/bin/pip" install \
    "diffusers>=0.32.0" transformers accelerate safetensors peft \
    huggingface_hub "gradio>=4.0.0" "imageio[ffmpeg]" pillow sentencepiece protobuf \
    xformers einops opencv-python-headless scikit-image scipy \
    comfyui-frontend-package comfyui-comfy-package

  if [[ ! -d "${COMFYUI_DIR}/ComfyUI/.git" ]]; then
    log "Cloning ComfyUI repository (shallow clone, no history)..."
    git clone --depth 1 --single-branch https://github.com/comfyanonymous/ComfyUI.git "${COMFYUI_DIR}/ComfyUI"
  else
    log "ComfyUI source already present; skipping git update."
  fi

  log "ComfyUI python environment ready."
}

get_diffusers_allow_patterns() {
  local model_id="$1"
  local stack_kind="$2"
  
  case "${model_id}" in
    black-forest-labs/FLUX.2-dev|black-forest-labs/FLUX.1-dev)
      cat <<PATTERNS
model_index.json
scheduler/*
text_encoder/*
tokenizer/*
transformer/*
PATTERNS
      ;;
    stabilityai/stable-diffusion-xl-base-1.0)
      cat <<PATTERNS
model_index.json
scheduler/*
text_encoder/*
text_encoder_2/*
tokenizer/*
tokenizer_2/*
unet/*
vae/*
feature_extractor/*
PATTERNS
      ;;
    Wan-AI/Wan2.1-T2V-14B-Diffusers|Wan-AI/Wan2.1-I2V-14B-720P-Diffusers)
      cat <<PATTERNS
model_index.json
scheduler/*
tokenizer*/*
text_encoder*/*
transformer/*
vae/*
feature_extractor/*
image_encoder/*
PATTERNS
      ;;
    *)
      cat <<PATTERNS
model_index.json
scheduler/*
text_encoder*/*
tokenizer*/*
transformer/*
unet/*
vae/*
PATTERNS
      ;;
  esac
}

download_image_loras() {
  local lora_dir="${MODEL_DIR_BASE}/loras"
  local entries
  local failed=0
  local failed_names=()
  mkdir -p "${lora_dir}"

  entries=$(python3 - <<'PY'
import json
import os
from urllib.parse import urlparse

raw = os.environ.get("IMAGE_LORAS_JSON", "[]")
try:
    data = json.loads(raw)
except Exception:
    data = []

for item in data:
    if isinstance(item, str):
        url = item.strip()
        if not url:
            continue
        name = os.path.basename(urlparse(url).path) or "lora.safetensors"
        if "." not in os.path.basename(name):
            name = f"{name}.safetensors"
        print(f"{url}\t{name}")
    elif isinstance(item, dict):
        url = str(item.get("url", "")).strip()
        if not url:
            continue
        name = str(item.get("filename") or item.get("name") or os.path.basename(urlparse(url).path) or "lora.safetensors").strip()
        if name:
            if "." not in os.path.basename(name):
                name = f"{name}.safetensors"
            print(f"{url}\t{name}")
PY
)

  [[ -n "${entries}" ]] || {
    log "No image LoRAs configured in stacks.yaml."
    return 0
  }

  # Build list of expected filenames for cleanup
  local -a expected_files=()
  while IFS=$'\t' read -r _url fname; do
    [[ -n "${fname}" ]] && expected_files+=("${fname}")
  done <<< "${entries}"

  # Remove .safetensors files that are no longer in the configured list
  if [[ -d "${lora_dir}" ]]; then
    for existing in "${lora_dir}"/*.safetensors; do
      [[ -f "${existing}" ]] || continue
      local base
      base="$(basename "${existing}")"
      local keep=0
      for expected in "${expected_files[@]}"; do
        if [[ "${base}" == "${expected}" ]]; then
          keep=1
          break
        fi
      done
      if [[ "${keep}" -eq 0 ]]; then
        log "Removing obsolete LoRA: ${base}"
        rm -f "${existing}"
      fi
    done
  fi

  log "Ensuring configured image LoRAs in ${lora_dir}..."
  while IFS=$'\t' read -r url filename; do
    [[ -n "${url}" && -n "${filename}" ]] || continue
    local target="${lora_dir}/${filename}"
    local tmp_target="${target}.part"
    if [[ -f "${target}" ]]; then
      log "LoRA already present: ${filename}"
      continue
    fi
    log "Downloading LoRA: ${filename}"
    rm -f "${tmp_target}" >/dev/null 2>&1 || true
    if [[ -n "${HF_TOKEN:-}" ]]; then
      if curl -L --fail --retry 3 --retry-delay 5 \
        -H "Authorization: Bearer ${HF_TOKEN}" \
        -o "${tmp_target}" "${url}"; then
        mv "${tmp_target}" "${target}"
        log "LoRA download complete: ${filename}"
      else
        rm -f "${tmp_target}" >/dev/null 2>&1 || true
        failed=1
        failed_names+=("${filename}")
        log "WARNING: LoRA download failed, skipping: ${filename}"
      fi
    else
      if curl -L --fail --retry 3 --retry-delay 5 \
        -o "${tmp_target}" "${url}"; then
        mv "${tmp_target}" "${target}"
        log "LoRA download complete: ${filename}"
      else
        rm -f "${tmp_target}" >/dev/null 2>&1 || true
        failed=1
        failed_names+=("${filename}")
        log "WARNING: LoRA download failed, skipping: ${filename}"
      fi
    fi
  done <<< "${entries}"

  if [[ "${failed}" -eq 1 ]]; then
    log "WARNING: Some image LoRAs could not be downloaded: ${failed_names[*]}"
  fi

  return 0
}

write_image_app_py() {
  mkdir -p "${APP_DIR}"
  if [[ -n "${IMAGE_APP_SOURCE}" && -f "${IMAGE_APP_SOURCE}" ]]; then
    install -m 0644 "${IMAGE_APP_SOURCE}" "${APP_DIR}/app.py"
    log "Using uploaded image app source: ${IMAGE_APP_SOURCE}"
    return 0
  fi
  cat > "${APP_DIR}/app.py" <<'PY'
import os, time, torch, gradio as gr
from pathlib import Path
from safetensors import safe_open

MODEL_ID = os.environ.get("MODEL_ID")
DEVICE   = "cuda" if torch.cuda.is_available() else "cpu"
DTYPE    = torch.float16 if DEVICE == "cuda" else torch.float32
LORA_DIR = Path("/opt/models/loras")

pipe = None
INCOMPATIBLE_LORAS = {}

# ── LoRA discovery ────────────────────────────────────────────────────────

UNSUPPORTED_LORA_MARKERS = {
    ".lora_mid.": "unsupported LyCORIS/LoCon weights",
    ".hada_": "unsupported LoHa weights",
    ".lokr_": "unsupported LoKr weights",
}

def scan_loras():
    try:
        if not LORA_DIR.is_dir():
            return []
        return sorted(
            [p for p in LORA_DIR.rglob("*.safetensors") if p.is_file()],
            key=lambda p: (p.name.lower(), str(p)),
        )
    except Exception:
        return []

def inspect_lora(path: Path):
    try:
        with safe_open(str(path), framework="pt", device="cpu") as handle:
            keys = list(handle.keys())
        if not keys:
            return False, "file contains no tensor weights"
        for marker, reason in UNSUPPORTED_LORA_MARKERS.items():
            if any(marker in key for key in keys):
                return False, reason
        if any(k.startswith("transformer.") or k.startswith("lora_transformer.") for k in keys):
            print(f"[lora][BLOCKED] {path.name}: Flux LoRA (incompatible with SDXL)", flush=True)
            return False, "Flux LoRA — incompatible with SDXL pipeline"
        return True, ""
    except Exception as exc:
        return False, f"failed to inspect file: {exc}"

def split_loras(paths):
    compatible = {}
    incompatible = {}
    seen_labels = set()
    for path in paths:
        label = path.name
        if label in seen_labels:
            label = str(path.relative_to(LORA_DIR))
        seen_labels.add(label)
        is_compatible, reason = inspect_lora(path)
        if is_compatible:
            compatible[label] = str(path)
        else:
            incompatible[label] = reason
    return compatible, incompatible

LORA_PATHS = scan_loras()
COMPATIBLE_LORAS, INCOMPATIBLE_LORAS = split_loras(LORA_PATHS)
HAS_LORAS = bool(COMPATIBLE_LORAS)

LORA_LABEL_TO_PATH = {"None": None, **COMPATIBLE_LORAS}
COMPATIBLE_LABELS = list(COMPATIBLE_LORAS.keys())
LORA_LABELS = list(LORA_LABEL_TO_PATH.keys())

# ── Pipeline ──────────────────────────────────────────────────────────────

def load_base():
    global pipe
    if pipe is not None:
        return
    from diffusers import AutoPipelineForText2Image
    pipe = AutoPipelineForText2Image.from_pretrained(
        MODEL_ID,
        torch_dtype=DTYPE,
        variant="fp16" if DTYPE == torch.float16 else None,
    ).to(DEVICE)

# ── LoRA management ───────────────────────────────────────────────────────

def apply_loras(selected_labels, selected_weights):
    try:
        pipe.unload_lora_weights()
    except Exception:
        pass
    adapter_names = []
    adapter_weights = []
    seen_labels = set()

    for idx, (label, weight) in enumerate(zip(selected_labels, selected_weights), start=1):
        if not label or label == "None":
            continue
        if label in seen_labels:
            continue
        seen_labels.add(label)
        lora_path = LORA_LABEL_TO_PATH.get(label)
        if not lora_path:
            continue
        adapter_name = f"lora{idx}"
        print(f"Lade LoRA: {label}", flush=True)
        try:
            pipe.load_lora_weights(lora_path, adapter_name=adapter_name)
        except Exception as exc:
            raise RuntimeError(
                f"LoRA '{label}' konnte nicht geladen werden. "
                f"Sie ist vermutlich nicht diffusers-kompatibel oder passt nicht zum Basis-Modell. "
                f"Details: {exc}"
            ) from exc
        adapter_names.append(adapter_name)
        adapter_weights.append(float(weight))

    if adapter_names:
        pipe.set_adapters(adapter_names, adapter_weights=adapter_weights)

# ── Generation ────────────────────────────────────────────────────────────

def gen(prompt, neg, steps, guidance, w, h, seed, *lora_args):
    load_base()

    selected_labels = []
    selected_weights = []
    for idx in range(0, len(lora_args), 2):
        label = lora_args[idx]
        weight = lora_args[idx + 1] if idx + 1 < len(lora_args) else 0.75
        selected_labels.append(label)
        selected_weights.append(weight)

    try:
        apply_loras(selected_labels, selected_weights)
    except Exception as exc:
        return None, f"LoRA error – {exc}"

    g   = torch.Generator(device=DEVICE).manual_seed(int(seed))
    t0  = time.time()
    out = pipe(
        prompt=prompt,
        negative_prompt=neg or None,
        num_inference_steps=int(steps),
        guidance_scale=float(guidance),
        width=int(w),
        height=int(h),
        generator=g,
    )
    active = [(selected_labels[i], selected_weights[i]) for i in range(len(selected_labels)) if selected_labels[i] and selected_labels[i] != "None"]
    lora_tag = "  |  " + ", ".join(f"{l}@{w:.2f}" for l, w in active) if active else ""
    return out.images[0], f"{time.time()-t0:.1f}s on {DEVICE}  |  steps={steps}  cfg={guidance}{lora_tag}"

# ── UI ────────────────────────────────────────────────────────────────────

with gr.Blocks(title="Image Generator") as demo:
    gr.Markdown(f"## Image Generator\nModel: `{MODEL_ID}` | Device: `{DEVICE}`")

    DEFAULT_NEG = (
        "anime, cartoon, graphic, text, painting, crayon, graphite, abstract, "
        "glitch, deformed, mutated, plastic, surreal, overexposed, "
        "blurry, distorted, low quality"
    )

    prompt = gr.Textbox(label="Prompt", value="a cinematic photo of a robot in a forest, 35mm")
    neg    = gr.Textbox(label="Negative Prompt", value=DEFAULT_NEG, lines=2)

    with gr.Row():
        steps    = gr.Slider(minimum=1, maximum=50, value=4,   step=1,   label="Steps")
        guidance = gr.Slider(minimum=1.0, maximum=10.0, value=1.5, step=0.5, label="Guidance Scale (CFG)")

    with gr.Row():
        w    = gr.Slider(512, 1536, 1024, step=64, label="Width")
        h    = gr.Slider(512, 1536, 1024, step=64, label="Height")
        seed = gr.Number(42, precision=0, label="Seed")

    lora_inputs = []

    # LoRA accordion – dynamic number of slots based on compatible files
    with gr.Accordion(
        label=(
            f"LoRA Settings  ({len(COMPATIBLE_LORAS)} compatible file(s), dynamic slots)"
            if HAS_LORAS else
            "LoRA Settings  (no compatible .safetensors found in /opt/models/loras)"
        ),
        open=HAS_LORAS,
    ):
        if HAS_LORAS:
            gr.Markdown(
                f"Es gibt {len(COMPATIBLE_LABELS)} kompatible LoRAs. "
                "Fuer jede Datei wird automatisch ein eigener Slot erzeugt."
            )
            for idx in range(len(COMPATIBLE_LABELS)):
                with gr.Row():
                    lora_dropdown = gr.Dropdown(
                        choices=LORA_LABELS,
                        value="None",
                        label=f"LoRA Slot {idx + 1}",
                        interactive=True,
                    )
                    lora_scale = gr.Slider(
                        0.0, 1.0,
                        value=0.75,
                        step=0.05,
                        label=f"LoRA Slot {idx + 1} Weight",
                        interactive=True,
                    )
                lora_inputs.extend([lora_dropdown, lora_scale])
        else:
            gr.Markdown(
                "_Drop \`.safetensors\` files into \`/opt/models/loras/\` and restart the app._"
            )
        if INCOMPATIBLE_LORAS:
            skipped_lines = [
                f"- `{label}`: {reason}"
                for label, reason in sorted(INCOMPATIBLE_LORAS.items())
            ]
            gr.Markdown(
                "### Skipped incompatible LoRAs\n"
                + "\n".join(skipped_lines)
            )

    btn  = gr.Button("Generate", variant="primary")
    img  = gr.Image(label="Output")
    info = gr.Textbox(label="Info", interactive=False)

    btn.click(
        gen,
        inputs=[prompt, neg, steps, guidance, w, h, seed] + lora_inputs,
        outputs=[img, info],
    )

demo.queue().launch(
    server_name="127.0.0.1",
    server_port=int(os.environ.get("PORT", "7860")),
    share=False,
)
PY
}

start_image_ui() {
  local model_source="$1"
  if [[ -d "${IMAGE_MODEL_DIR}" && -f "${IMAGE_MODEL_DIR}/model_index.json" ]]; then
    model_source="${IMAGE_MODEL_DIR}"
  fi
  if pgrep -f "${APP_DIR}/app.py" &>/dev/null; then log "Image UI running."; return; fi
  MODEL_ID="${model_source}" HOST="${BIND_ADDR}" PORT="${IMAGE_PORT}" \
    nohup "${APP_VENV}/bin/python" "${APP_DIR}/app.py" >"${LOG_DIR}/image.log" 2>&1 &
  disown
  wait_for_port "${BIND_ADDR}" "${IMAGE_PORT}" 30 3
}

write_image_prompt_app_py() {
  mkdir -p "${APP_DIR}"
  if [[ -n "${IMAGE_APP_SOURCE}" && -f "${IMAGE_APP_SOURCE}" ]]; then
    install -m 0644 "${IMAGE_APP_SOURCE}" "${APP_DIR}/app_prompt.py"
    log "Using uploaded image_prompt app source: ${IMAGE_APP_SOURCE}"
    return 0
  fi
  cat > "${APP_DIR}/app_prompt.py" <<'PY'
import os
import time
import torch
import gradio as gr
from pathlib import Path
from diffusers import FluxPipeline

MODEL_ID = os.environ.get("MODEL_ID")
DEVICE = "cuda" if torch.cuda.is_available() else "cpu"
DTYPE = torch.bfloat16 if DEVICE == "cuda" else torch.float32
LORA_DIR = Path("/opt/models/loras")

pipe = None

# ── LoRA discovery ────────────────────────────────────────────────────────

def scan_loras():
    try:
        if not LORA_DIR.is_dir():
            return []
        return sorted(
            [p for p in LORA_DIR.rglob("*.safetensors") if p.is_file()],
            key=lambda p: (p.name.lower(), str(p)),
        )
    except Exception:
        return []

LORA_PATHS = scan_loras()
LORA_CHOICES = [("None", None)] + [(p.name, str(p)) for p in LORA_PATHS]
HAS_LORAS = bool(LORA_PATHS)

def load_pipeline():
    global pipe
    if pipe is not None:
        return pipe
    
    print(f"[info] Loading Flux model from {MODEL_ID}...", flush=True)
    t0 = time.time()
    
    # Load FluxPipeline with optimized settings for better compatibility
    pipe = FluxPipeline.from_pretrained(
        MODEL_ID,
        torch_dtype=DTYPE,
        use_safetensors=True,
    )
    
    # Enable memory optimizations
    if DEVICE == "cuda":
        # Enable xformers or sdp for better performance
        try:
            pipe.enable_xformers_memory_efficient_attention()
            print("[info] xformers attention enabled", flush=True)
        except Exception:
            try:
                pipe.enable_attention_slicing()
                print("[info] attention slicing enabled", flush=True)
            except Exception:
                pass
        
        # Enable VAE slicing for large images
        try:
            pipe.enable_vae_slicing()
            print("[info] VAE slicing enabled", flush=True)
        except Exception:
            pass
    
    pipe = pipe.to(DEVICE)
    elapsed = time.time() - t0
    print(f"[info] Model loaded in {elapsed:.1f}s", flush=True)
    return pipe

def generate_image(
    prompt, negative_prompt,
    lora_1, w1, lora_2, w2, lora_3, w3, lora_4, w4, lora_5, w5,
    steps, guidance, seed, width, height
):
    pipeline = load_pipeline()
    
    # Load LoRAs if selected
    adapters = []
    weights = []
    lora_pairs = [
        (lora_1, w1), (lora_2, w2), (lora_3, w3), (lora_4, w4), (lora_5, w5)
    ]
    
    for i, (lora_name, lora_weight) in enumerate(lora_pairs):
        if lora_name and lora_name != "None":
            # Find the path for this LoRA
            lora_path = None
            for path in LORA_PATHS:
                if path.name == lora_name:
                    lora_path = str(path)
                    break
            
            if lora_path:
                adapter_name = f"adapter_{i}"
                try:
                    pipeline.load_lora_weights(lora_path, adapter_name=adapter_name)
                    adapters.append(adapter_name)
                    weights.append(float(w1) if i == 0 else float(w2) if i == 1 else float(w3) if i == 2 else float(w4) if i == 3 else float(w5))
                    print(f"[info] Loaded LoRA: {lora_name} (weight={weights[-1]})", flush=True)
                except Exception as e:
                    print(f"[warn] Failed to load LoRA {lora_name}: {e}", flush=True)
    
    if adapters:
        pipeline.set_adapters(adapters, adapter_weights=weights)
        print(f"[info] Active adapters: {adapters} with weights {weights}", flush=True)
    
    # Prepare generator
    actual_seed = int(seed) if seed >= 0 else torch.randint(0, 2**31, (1,)).item()
    generator = torch.Generator(device=DEVICE).manual_seed(actual_seed)
    
    print(f"[info] Generating: {prompt[:80]}... (steps={steps}, guidance={guidance}, size={width}x{height})", flush=True)
    t0 = time.time()
    
    # Generate image
    output = pipeline(
        prompt=prompt,
        negative_prompt=negative_prompt if negative_prompt and negative_prompt.strip() else None,
        num_inference_steps=steps,
        guidance_scale=guidance,
        generator=generator,
        width=width,
        height=height,
    )
    
    image = output.images[0]
    elapsed = time.time() - t0
    
    # Unload LoRAs after generation
    if adapters:
        pipeline.unload_lora_weights()
        print("[info] LoRAs unloaded", flush=True)
    
    # Save and return
    import tempfile
    temp_file = tempfile.NamedTemporaryFile(suffix=".png", delete=False)
    image.save(temp_file.name, "PNG")
    
    active_loras = []
    for i, (name, _) in enumerate(lora_pairs):
        if name and name != "None":
            active_loras.append(name)
    
    lora_info = f" | LoRAs: {', '.join(active_loras)}" if active_loras else " | No LoRA"
    info = f"Prompt: {prompt}\nSize: {width}x{height} | Steps: {steps} | Guidance: {guidance} | Seed: {actual_seed}{lora_info}\nTime: {elapsed:.1f}s | Device: {DEVICE}"
    return temp_file.name, info

# ── UI ────────────────────────────────────────────────────────────────────

with gr.Blocks(title="FLUX.2 Text-to-Image", theme=gr.themes.Soft()) as demo:
    gr.Markdown("# 🎨 FLUX.2 Text-to-Image Studio")
    gr.Markdown("Generiere hochwertige Bilder aus Text-Prompts mit FLUX.2-dev")
    gr.Markdown(f"**Model:** `{MODEL_ID}` | **Device:** `{DEVICE}` | **LoRAs available:** {len(LORA_PATHS)}")

    with gr.Row():
        with gr.Column(scale=1):
            prompt = gr.Textbox(
                label="Prompt",
                placeholder="Beschreibe das Bild...",
                value="Photorealistic portrait of a stunning woman, elegant dress, cinematic lighting, 8k",
                lines=3
            )
            negative_prompt = gr.Textbox(
                label="Negative Prompt (optional)",
                value="ugly, deformed, noisy, blurry, low quality, distorted, disfigured, bad anatomy",
                lines=2
            )

            if HAS_LORAS:
                gr.Markdown("### 🎭 LoRAs (optional)")
                lora_components = []
                for i in range(5):
                    with gr.Row():
                        lora_drop = gr.Dropdown(
                            choices=LORA_CHOICES,
                            value="None",
                            label=f"LoRA {i+1}"
                        )
                        lora_scale = gr.Slider(0, 1, value=0.75, step=0.05, label="Gewicht")
                        lora_components.extend([lora_drop, lora_scale])
            else:
                gr.Markdown("### 🎭 LoRAs")
                gr.Markdown("_Keine LoRAs gefunden. Lege `.safetensors` Dateien nach `/opt/models/loras/` und starte neu._")
                # Add hidden dummy components to keep parameter count consistent
                lora_components = []
                for i in range(5):
                    with gr.Row(visible=False):
                        lora_drop = gr.Dropdown(choices=["None"], value="None", label=f"LoRA {i+1}")
                        lora_scale = gr.Slider(0, 1, value=0, step=0.05, label="Gewicht")
                        lora_components.extend([lora_drop, lora_scale])

            gr.Markdown("### ⚙️ Einstellungen")
            steps = gr.Slider(1, 50, value=28, step=1, label="Steps")
            guidance = gr.Slider(1, 10, value=3.5, step=0.5, label="Guidance")
            seed = gr.Number(value=42, precision=0, label="Seed (-1 für zufällig)")
            with gr.Row():
                width = gr.Slider(256, 1536, value=1024, step=64, label="Breite")
                height = gr.Slider(256, 1536, value=1024, step=64, label="Höhe")

            btn = gr.Button("🚀 Generieren", variant="primary", size="lg")

        with gr.Column(scale=1):
            output_image = gr.Image(label="Ergebnis", type="filepath")
            output_info = gr.Textbox(label="Info", lines=4)

    btn.click(
        fn=generate_image,
        inputs=[prompt, negative_prompt] + lora_components + [steps, guidance, seed, width, height],
        outputs=[output_image, output_info]
    )

    gr.Examples(
        examples=[
            ["Photorealistic portrait of a stunning woman, black pageboy haircut, striking blue eyes, cinematic lighting, 8k"],
            ["Majestic landscape, snow-capped mountains, golden hour, dramatic clouds, photorealistic"],
            ["Futuristic cityscape at night, neon lights, cyberpunk style, highly detailed"],
            ["Cozy cabin in the forest, autumn leaves, warm lighting, photorealistic"],
            ["Elegant fashion portrait, studio lighting, high detail skin texture"],
        ],
        inputs=[prompt]
    )

demo.queue(max_size=10).launch(
    server_name=os.environ.get("HOST", "127.0.0.1"),
    server_port=int(os.environ.get("PORT", "7863")),
    share=False,
)
PY
}

start_image_prompt_ui() {
  local model_source="$1"
  if [[ -d "${IMAGE_PROMPT_MODEL_DIR}" && -f "${IMAGE_PROMPT_MODEL_DIR}/model_index.json" ]]; then
    model_source="${IMAGE_PROMPT_MODEL_DIR}"
  fi
  if pgrep -f "${APP_DIR}/app_prompt.py" &>/dev/null; then log "Image Prompt UI running."; return; fi
  MODEL_ID="${model_source}" HOST="${BIND_ADDR}" PORT="${IMAGE_PROMPT_PORT:-7863}" \
    nohup "${APP_VENV}/bin/python" "${APP_DIR}/app_prompt.py" >"${LOG_DIR}/image_prompt.log" 2>&1 &
  disown
  wait_for_port "${BIND_ADDR}" "${IMAGE_PROMPT_PORT:-7863}" 30 3
}

start_comfyui_ui() {
  local model_source="$1"
  if [[ -d "${COMFYUI_MODEL_DIR}" && -f "${COMFYUI_MODEL_DIR}/model_index.json" ]]; then
    model_source="${COMFYUI_MODEL_DIR}"
  fi
  if pgrep -f "main.py.*--listen" &>/dev/null || pgrep -f "comfyui.*--port" &>/dev/null; then
    log "ComfyUI already running."
    return
  fi
  log "Starting ComfyUI on ${BIND_ADDR}:${COMFYUI_PORT}..."
  cd "${COMFYUI_DIR}/ComfyUI"
  MODEL_PATH="${model_source}" \
    nohup "${COMFYUI_VENV}/bin/python" main.py \
      --listen "${BIND_ADDR}" \
      --port "${COMFYUI_PORT}" \
      --output-directory "${COMFYUI_DIR}/output" \
      --temp-directory "${COMFYUI_DIR}/temp" \
      --input-directory "${COMFYUI_DIR}/input" \
      --disable-auto-launch \
      >"${LOG_DIR}/comfyui.log" 2>&1 &
  disown
  wait_for_port "${BIND_ADDR}" "${COMFYUI_PORT}" 60 5
}

write_start_comfyui_script() {
  mkdir -p "${COMFYUI_DIR}"
  cat > "${COMFYUI_DIR}/start_comfyui.sh" <<'ONSTART'
#!/usr/bin/env bash
set -euo pipefail
LOG_DIR="/var/log/stack"
BIND_ADDR="127.0.0.1"
COMFYUI_PORT="${COMFYUI_PORT:-7867}"
COMFYUI_DIR="/opt/comfyui"
COMFYUI_VENV="${COMFYUI_DIR}/venv"
MODEL_PATH="${MODEL_PATH:-/opt/models/comfyui/model}"

log() { echo "[$(date '+%H:%M:%S')] $*"; }

mkdir -p "${LOG_DIR}" "${COMFYUI_DIR}/output" "${COMFYUI_DIR}/temp" "${COMFYUI_DIR}/input"

log "=== Starting ComfyUI ==="

if ! pgrep -f "main.py.*--listen" &>/dev/null; then
  cd "${COMFYUI_DIR}/ComfyUI"
  nohup "${COMFYUI_VENV}/bin/python" main.py \
    --listen "${BIND_ADDR}" \
    --port "${COMFYUI_PORT}" \
    --output-directory "${COMFYUI_DIR}/output" \
    --temp-directory "${COMFYUI_DIR}/temp" \
    --input-directory "${COMFYUI_DIR}/input" \
    --disable-auto-launch \
    >"${LOG_DIR}/comfyui.log" 2>&1 &
  disown
fi

ready=0
for i in $(seq 1 60); do
  if curl -sf "http://${BIND_ADDR}:${COMFYUI_PORT}" >/dev/null 2>&1; then
    log "ComfyUI ready on port ${COMFYUI_PORT}"
    ready=1
    break
  fi
  if (( i == 1 || i % 10 == 0 )); then
    log "ComfyUI noch nicht bereit (${i}s). Log: ${LOG_DIR}/comfyui.log"
  fi
  sleep 1
done

if (( ready == 1 )); then
  log "ComfyUI started."
else
  log "ComfyUI noch im Start. Pruefe ${LOG_DIR}/comfyui.log"
fi
ONSTART
  chmod +x "${COMFYUI_DIR}/start_comfyui.sh"
  log "Created ${COMFYUI_DIR}/start_comfyui.sh for ComfyUI stack."
}

# ── Safe HuggingFace Download Helper ─────────────────────────────────────
# Uses hf_safe_download.py for safe, controlled downloads

pull_hf_model_safe() {
  local model_id="$1"
  local stack_name="${2:-image}"
  local target_dir
  target_dir="$(diffusers_model_dir_for_stack "${stack_name}")"
  local max_size_gb=40
  
  # Model-specific limits
  case "${model_id}" in
    black-forest-labs/FLUX.2-dev|black-forest-labs/FLUX.1-dev)
      max_size_gb=50
      log "[hf] FLUX model: max ${max_size_gb}GB (NO vae, NO image_encoder)"
      ;;
    Wan-AI/Wan2.1-T2V-14B-Diffusers|Wan-AI/Wan2.1-I2V-14B-720P-Diffusers)
      max_size_gb=45
      log "[hf] Wan2.1 model: max ${max_size_gb}GB"
      ;;
    stabilityai/stable-diffusion-xl-base-1.0)
      max_size_gb=20
      log "[hf] SDXL model: max ${max_size_gb}GB"
      ;;
    *)
      log "[hf] Unknown model: using default max ${max_size_gb}GB"
      ;;
  esac
  
  log "Downloading model: ${model_id}"
  log "Target: ${target_dir}"
  log "Max size: ${max_size_gb}GB"
  
  # Use the safe download Python module
  MODEL_ID="${model_id}" TARGET_DIR="${target_dir}" MAX_SIZE_GB="${max_size_gb}" \
    HF_TOKEN="${HF_TOKEN:-${HUGGINGFACE_HUB_TOKEN:-}}" \
    "${APP_VENV:-${VIDEO_VENV}}/bin/python" "${SCRIPT_DIR:-/root}/hf_safe_download.py" \
    --model "${model_id}" \
    --output "${target_dir}" \
    --max-size-gb "${max_size_gb}" \
    ${VERBOSE:+--verbose}
  
  local rc=$?
  if [[ ${rc} -eq 0 ]]; then
    log "✓ Model download complete: ${model_id}"
    return 0
  else
    log "✗ Model download failed: ${model_id}"
    return 1
  fi
}

pull_hf_model() {
  [[ "${PULL_MODEL}" == "1" ]] || return
  log "Downloading HF model: ${1} (safe download with size check)..."
  if [[ -n "${HF_TOKEN:-${HUGGINGFACE_HUB_TOKEN:-}}" ]]; then
    log "[hf] token detected for model download"
  else
    log "[hf] token missing for model download"
  fi
  local model_id="$1"
  local stack_name="image"
  if [[ "${model_id}" == "${IMAGE_PROMPT_DEFAULT_MODEL}" ]] || [[ "${STACK_TYPE}" == "image_prompt" ]]; then
    stack_name="image_prompt"
  elif [[ "${model_id}" == "${COMFYUI_DEFAULT_MODEL}" ]] || [[ "${STACK_TYPE}" == "comfyui" ]]; then
    stack_name="comfyui"
  fi
  
  pull_hf_model_safe "${model_id}" "${stack_name}"
  return $?
}

# ── VIDEO (v3: fully automated Wan2.1 in-process) ────────────────────────

install_video_env() {
  log "Creating video venv..."
  mkdir -p "${VIDEO_DIR}" "${MODEL_DIR_BASE}/loras"
  [[ -f "${VIDEO_VENV}/bin/activate" ]] || python3 -m venv "${VIDEO_VENV}"

  log "Installing Python deps (torch cu121, diffusers>=0.32, gradio, flash-attn)..."
  run_with_heartbeat "Video pip upgrade" "${VIDEO_VENV}/bin/pip" install --upgrade pip -q
  if ! run_with_heartbeat "Video torch install" \
    "${VIDEO_VENV}/bin/pip" install \
    torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu121; then
    log "Falling back to default torch index for video stack..."
    run_with_heartbeat "Video torch install (fallback)" \
      "${VIDEO_VENV}/bin/pip" install torch torchvision torchaudio
  fi
  run_with_heartbeat "Video python deps install" "${VIDEO_VENV}/bin/pip" install \
    "diffusers>=0.32.0,<0.37.0" \
    "transformers>=4.49.0,<5.0.0" \
    "tokenizers>=0.20.3,<0.22.0" \
    "accelerate>=0.30.0" \
    safetensors peft huggingface_hub \
    hf_transfer \
    pillow \
    "gradio>=4.0.0" \
    "imageio[ffmpeg]" \
    sentencepiece ftfy
  # flash-attn optional (huge speedup on Ampere+)
  run_with_heartbeat "Video flash-attn install" \
    "${VIDEO_VENV}/bin/pip" install -q --no-build-isolation flash-attn 2>/dev/null \
    || log "flash-attn skipped (OK, uses SDPA)"
}

pull_video_model() {
  [[ "${PULL_MODEL}" == "1" ]] || return
  log "Downloading video model: ${1} (safe download with size check)..."
  local model_id="$1"
  local stack_name="${2:-video}"
  
  pull_hf_model_safe "${model_id}" "${stack_name}"
  return $?
}

pull_video_i2v_model() {
  [[ "${PULL_MODEL}" == "1" ]] || return
  log "Downloading video I2V model: ${1} (safe download with size check)..."
  local model_id="$1"
  
  pull_hf_model_safe "${model_id}" "video_i2v"
  return $?
}

write_video_i2v_py() {
  local model="$1"
  local model_source="$model"
  local local_model_dir
  local_model_dir="$(diffusers_model_dir_for_stack video_i2v)"
  if [[ -d "${local_model_dir}" && -f "${local_model_dir}/model_index.json" ]]; then
    model_source="${local_model_dir}"
  fi
  log "Writing ${VIDEO_DIR}/video_i2v.py ..."
  cat > "${VIDEO_DIR}/video_i2v.py" <<PYEOF
#!/usr/bin/env python3
import argparse
import os
from pathlib import Path
import torch
from PIL import Image
from diffusers import WanImageToVideoPipeline
from diffusers.utils import export_to_video

DEFAULT_MODEL = os.environ.get("MODEL_ID", "${model_source}")

def clamp16(v: int) -> int:
    return max(16, (int(v) // 16) * 16)

def frames_for(seconds: float, fps: int) -> int:
    target = max(1, int(round(float(seconds) * int(fps))))
    return max(1, ((target - 1) // 4) * 4 + 1)

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", default=DEFAULT_MODEL)
    ap.add_argument("--image", required=True)
    ap.add_argument("--prompt", required=True)
    ap.add_argument("--negative", default="")
    ap.add_argument("--output", required=True)
    ap.add_argument("--steps", type=int, default=30)
    ap.add_argument("--guidance", type=float, default=5.0)
    ap.add_argument("--fps", type=int, default=24)
    ap.add_argument("--seconds", type=float, default=8.0)
    ap.add_argument("--seed", type=int, default=None)
    ap.add_argument("--width", type=int, default=None)
    ap.add_argument("--height", type=int, default=None)
    args = ap.parse_args()

    image = Image.open(args.image).convert("RGB")
    width = clamp16(args.width if args.width else image.width)
    height = clamp16(args.height if args.height else image.height)
    num_frames = frames_for(args.seconds, args.fps)

    device = "cuda" if torch.cuda.is_available() else "cpu"
    dtype = torch.bfloat16 if device == "cuda" else torch.float32
    pipe = WanImageToVideoPipeline.from_pretrained(args.model, torch_dtype=dtype)
    if device == "cuda":
      vram = torch.cuda.get_device_properties(0).total_memory / 1024**3
      if vram < 80:
          pipe.enable_model_cpu_offload()
      else:
          pipe.to("cuda")

    gen = torch.Generator(device="cpu")
    if args.seed is not None:
        gen.manual_seed(int(args.seed))

    out = pipe(
      image=image,
      prompt=args.prompt,
      negative_prompt=args.negative or None,
      num_inference_steps=int(args.steps),
      guidance_scale=float(args.guidance),
      width=width,
      height=height,
      num_frames=num_frames,
      generator=gen,
    )
    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    export_to_video(out.frames[0], str(output), fps=int(args.fps))
    print(str(output))

if __name__ == "__main__":
    main()
PYEOF
  chmod +x "${VIDEO_DIR}/video_i2v.py"
}

video_ui_script_name_for_stack() {
  case "$1" in
    video_lora) echo "video_lora_ui.py" ;;
    *) echo "video_ui.py" ;;
  esac
}

video_log_file_for_stack() {
  case "$1" in
    video_lora) echo "${LOG_DIR}/video_lora.log" ;;
    *) echo "${LOG_DIR}/video.log" ;;
  esac
}

video_port_for_stack() {
  case "$1" in
    video_lora) echo "${VIDEO_LORA_PORT}" ;;
    *) echo "${VIDEO_PORT}" ;;
  esac
}

diffusers_model_dir_for_stack() {
  case "$1" in
    image) echo "${IMAGE_MODEL_DIR}" ;;
    video) echo "${VIDEO_MODEL_DIR}" ;;
    video_lora) echo "${VIDEO_LORA_MODEL_DIR}" ;;
    video_i2v) echo "${VIDEO_I2V_MODEL_DIR}" ;;
    comfyui) echo "${COMFYUI_MODEL_DIR}" ;;
    *) echo "${MODEL_DIR_BASE}/$1/model" ;;
  esac
}

write_video_ui() {
  local model="$1"
  local stack_name="${2:-video}"
  local script_name script_path default_port lora_enabled title model_source
  script_name="$(video_ui_script_name_for_stack "${stack_name}")"
  script_path="${VIDEO_DIR}/${script_name}"
  default_port="$(video_port_for_stack "${stack_name}")"
  model_source="$model"
  local local_model_dir
  local_model_dir="$(diffusers_model_dir_for_stack "${stack_name}")"
  if [[ -d "${local_model_dir}" && -f "${local_model_dir}/model_index.json" ]]; then
    model_source="${local_model_dir}"
  fi
  if [[ "${stack_name}" == "video_lora" ]]; then
    lora_enabled="True"
    title="Wan2.1 Video LoRA Studio"
  else
    lora_enabled="False"
    title="Wan2.1 Video Studio"
  fi

  log "Writing ${script_path} ..."
  cat > "${script_path}" <<PYEOF
#!/usr/bin/env python3
"""
${title} — Wan2.1-T2V-14B-Diffusers in-process + multi-clip + ffmpeg stitch.
"""
import gc, os, shutil, subprocess, time, traceback
from pathlib import Path
from typing import List, Optional

import gradio as gr
import torch

MODEL_ID = os.environ.get("MODEL_ID", "${model_source}")
DEVICE = "cuda" if torch.cuda.is_available() else "cpu"
DTYPE = torch.bfloat16
LORA_ENABLED = ${lora_enabled}
VRAM_GB = 0
if DEVICE == "cuda":
    VRAM_GB = torch.cuda.get_device_properties(0).total_memory / 1024**3

BIND = os.environ.get("VIDEO_UI_HOST", "127.0.0.1")
PORT = int(os.environ.get("VIDEO_UI_PORT", "${default_port}"))
LORA_DIR = Path("/opt/models/loras")

pipe = None
_active_lora = None


def scan_loras():
    try:
        if not LORA_ENABLED or not LORA_DIR.is_dir():
            return []
        return sorted(LORA_DIR.rglob("*.safetensors"), key=lambda p: p.name)
    except Exception:
        return []


LORA_PATHS = scan_loras()
HAS_LORAS = bool(LORA_PATHS)
LORA_LABEL_TO_PATH = {"None": None}
for _path in LORA_PATHS:
    LORA_LABEL_TO_PATH[_path.name] = str(_path)
LORA_LABELS = list(LORA_LABEL_TO_PATH.keys())


def load_pipeline():
    global pipe
    if pipe is not None:
        return
    from diffusers import WanPipeline

    print(f"Loading {MODEL_ID} (bfloat16)...", flush=True)
    pipe = WanPipeline.from_pretrained(MODEL_ID, torch_dtype=DTYPE)
    if DEVICE == "cuda" and VRAM_GB < 80:
        pipe.enable_model_cpu_offload()
        print(f"  CPU offload enabled (VRAM={VRAM_GB:.0f}GB < 80GB)", flush=True)
    else:
        pipe.to(DEVICE)
    try:
        pipe.enable_xformers_memory_efficient_attention()
        print("  xformers attention enabled", flush=True)
    except Exception:
        print("  Using default SDPA attention", flush=True)
    print(f"Pipeline ready on {DEVICE} ({VRAM_GB:.0f}GB VRAM)", flush=True)


def unload_lora():
    global _active_lora
    if _active_lora is None or pipe is None:
        return
    try:
        pipe.unload_lora_weights()
        print(f"[lora] unloaded: {Path(_active_lora).name}", flush=True)
    except Exception as exc:
        print(f"[lora][warn] unload failed: {exc}", flush=True)
    _active_lora = None


def apply_lora(lora_label: str, lora_scale: float) -> Optional[str]:
    global _active_lora
    if not LORA_ENABLED:
        return None

    lora_path = LORA_LABEL_TO_PATH.get(lora_label)
    if lora_path is None:
        unload_lora()
        return None

    load_pipeline()
    if lora_path != _active_lora:
        unload_lora()
        lora_file = Path(lora_path)
        print(f"[lora] loading: {lora_file.name}", flush=True)
        pipe.load_lora_weights(
            str(lora_file.parent),
            weight_name=lora_file.name,
            adapter_name="default",
        )
        _active_lora = lora_path
    else:
        print(f"[lora] cache hit: {Path(lora_path).name}", flush=True)

    pipe.set_adapters("default", adapter_weights=[float(lora_scale)])
    return lora_path


def gen_single_clip(
    prompt: str,
    negative: str,
    steps: int,
    guidance: float,
    height: int,
    width: int,
    num_frames: int,
    fps: int,
    seed: Optional[int],
    lora_label: str,
    lora_scale: float,
    out_path: Path,
) -> dict:
    load_pipeline()
    from diffusers.utils import export_to_video

    active_lora = None
    if LORA_ENABLED:
        active_lora = apply_lora(lora_label, lora_scale)

    h = height // 16 * 16
    w = width // 16 * 16
    f = max(1, (num_frames - 1) // 4 * 4 + 1)

    gen = torch.Generator(device="cpu")
    if seed is not None:
        gen.manual_seed(seed)

    t0 = time.time()
    output = pipe(
        prompt=prompt,
        negative_prompt=negative.strip() if negative and negative.strip() else None,
        num_inference_steps=steps,
        guidance_scale=guidance,
        height=h,
        width=w,
        num_frames=f,
        generator=gen,
    )
    frames = output.frames[0]
    export_to_video(frames, str(out_path), fps=fps)
    elapsed = time.time() - t0

    gc.collect()
    if DEVICE == "cuda":
        torch.cuda.empty_cache()

    return {
        "path": str(out_path),
        "frames": len(frames),
        "elapsed": elapsed,
        "resolution": f"{w}x{h}",
        "lora": Path(active_lora).name if active_lora else "",
    }


def _run(cmd: list) -> None:
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        raise RuntimeError(f"Command failed: {' '.join(cmd)}\\nSTDERR: {result.stderr}")


def stitch_concat(clips: List[Path], out: Path) -> None:
    concat = out.parent / "concat.txt"
    concat.write_text("\\n".join(f"file '{clip}'" for clip in clips) + "\\n")
    try:
        _run(["ffmpeg", "-y", "-f", "concat", "-safe", "0", "-i", str(concat), "-c", "copy", str(out)])
    except Exception:
        _run([
            "ffmpeg", "-y", "-f", "concat", "-safe", "0", "-i", str(concat),
            "-c:v", "libx264", "-crf", "18", "-preset", "medium", str(out),
        ])


def stitch_xfade(clips: List[Path], out: Path, clip_secs: float, fade: float, fps: int) -> None:
    inputs = []
    for clip in clips:
        inputs += ["-i", str(clip)]
    prev = "[0:v]"
    parts = []
    for idx in range(1, len(clips)):
        offset = max(idx * (clip_secs - fade), 0.0)
        cur = f"[{idx}:v]"
        tag = f"[v{idx}]"
        parts.append(f"{prev}{cur}xfade=transition=fade:duration={fade}:offset={offset}{tag}")
        prev = tag
    _run(["ffmpeg", "-y", *inputs, "-filter_complex", ";".join(parts), "-map", prev, "-r", str(fps), "-c:v", "libx264", "-crf", "18", str(out)])


def make_video(
    prompt, negative, num_clips, seconds_per_clip, fps,
    steps, guidance, width, height,
    fade_seconds, seed, seed_mode,
    lora_label="None", lora_scale=0.8,
    progress=gr.Progress(track_tqdm=True),
):
    if not prompt.strip():
        raise gr.Error("Please enter a prompt.")

    run_dir = Path("/root/video_runs") / time.strftime("%Y%m%d_%H%M%S")
    run_dir.mkdir(parents=True, exist_ok=True)

    num_clips = int(num_clips)
    fps_val = int(fps)
    frames_per_clip = max(1, (int(float(seconds_per_clip) * fps_val) - 1) // 4 * 4 + 1)

    clips: List[Path] = []
    infos: List[str] = []

    for idx in range(num_clips):
        progress(idx / num_clips, desc=f"Generating clip {idx+1}/{num_clips}...")
        clip_path = run_dir / f"clip_{idx:03d}.mp4"

        if seed_mode == "fixed":
            current_seed = int(seed)
        elif seed_mode == "increment":
            current_seed = int(seed) + idx
        else:
            current_seed = None

        try:
            info = gen_single_clip(
                prompt=prompt,
                negative=negative,
                steps=int(steps),
                guidance=float(guidance),
                height=int(height),
                width=int(width),
                num_frames=frames_per_clip,
                fps=fps_val,
                seed=current_seed,
                lora_label=lora_label,
                lora_scale=float(lora_scale),
                out_path=clip_path,
            )
        except Exception as exc:
            err = run_dir / "error.txt"
            err.write_text(traceback.format_exc())
            raise gr.Error(
                f"Generation failed on clip {idx+1}/{num_clips}: {exc}. "
                f"See {err} and /var/log/stack/${stack_name}.log"
            )

        if not clip_path.exists() or clip_path.stat().st_size == 0:
            err = run_dir / "error.txt"
            err.write_text(f"Clip {idx+1} was not written: {clip_path}\\n")
            raise gr.Error(f"Clip {idx+1} missing on disk. See {err}")

        clips.append(clip_path)
        lora_tag = f" | LoRA: {info['lora']}" if info.get("lora") else ""
        infos.append(f"Clip {idx+1}: {info['frames']}f in {info['elapsed']:.1f}s ({info['resolution']}){lora_tag}")

    progress(0.95, desc="Stitching clips...")
    final = run_dir / "final.mp4"
    try:
        if len(clips) == 1:
            shutil.copy2(clips[0], final)
        elif float(fade_seconds) > 0:
            stitch_xfade(clips, final, float(seconds_per_clip), float(fade_seconds), fps_val)
        else:
            stitch_concat(clips, final)
    except Exception:
        if clips:
            shutil.copy2(clips[0], final)
            infos.append("Stitch failed, fallback used: final.mp4 = first clip.")
        else:
            err = run_dir / "error.txt"
            err.write_text(traceback.format_exc())
            raise gr.Error(f"Stitch failed and no clips available. See {err}")

    if not final.exists() or final.stat().st_size == 0:
        if clips:
            shutil.copy2(clips[0], final)
            infos.append("Final file was missing; fallback copy from first clip created.")
        else:
            raise gr.Error(f"Final video missing in {run_dir}")

    summary = (
        f"**{num_clips} clips** | {frames_per_clip} frames/clip @ {fps_val}fps\\n"
        + "\\n".join(infos)
        + f"\\n\\nDevice: {DEVICE} ({VRAM_GB:.0f}GB) | Model: {MODEL_ID}"
    )
    if LORA_ENABLED and lora_label and lora_label != "None":
        summary += f"\\nLoRA: {lora_label} @ {float(lora_scale):.2f}"
    downloads = [str(final)] + [str(clip) for clip in clips]
    gallery = [str(clip) for clip in clips]
    return str(final), downloads, gallery, summary, str(run_dir)


with gr.Blocks(title="${title}") as demo:
    gr.Markdown(
        f"## 🎬 ${title} — Clips + Stitch\\n"
        f"Model: \`{MODEL_ID}\` | Device: \`{DEVICE}\` | VRAM: \`{VRAM_GB:.0f} GB\`\\n"
        f"> Generate multiple clips from one prompt, automatically stitched with crossfade."
    )

    with gr.Row():
        with gr.Column(scale=2):
            prompt = gr.Textbox(
                label="Prompt",
                lines=3,
                value="A cinematic drone shot over a glacial mountain lake at golden hour, mist rising, photorealistic, 4k",
            )
            negative = gr.Textbox(
                label="Negative prompt",
                value="blurry, low quality, watermark, ugly, distorted, nsfw",
                lines=2,
            )
        with gr.Column(scale=1):
            with gr.Row():
                num_clips = gr.Slider(1, 20, value=1, step=1, label="Number of clips")
                seconds_per_clip = gr.Slider(1, 10, value=3, step=0.5, label="Seconds / clip")
            with gr.Row():
                fps = gr.Slider(8, 30, value=16, step=1, label="FPS")
                steps = gr.Slider(10, 50, value=30, step=1, label="Inference steps")
            with gr.Row():
                guidance = gr.Slider(1, 15, value=5.0, step=0.5, label="Guidance scale")
                width = gr.Slider(256, 1280, value=832, step=16, label="Width (px)")
            with gr.Row():
                height = gr.Slider(256, 1280, value=480, step=16, label="Height (px)")
                fade_seconds = gr.Slider(0, 2, value=0.5, step=0.1, label="Crossfade (s)")
            with gr.Row():
                seed = gr.Number(value=42, precision=0, label="Base seed")
                seed_mode = gr.Radio(["fixed", "increment", "random"], value="increment", label="Seed mode")

    lora_dropdown = None
    lora_scale = None
    if LORA_ENABLED:
        with gr.Accordion(
            label=(
                f"LoRA Settings  ({len(LORA_PATHS)} file(s) found)"
                if HAS_LORAS else
                "LoRA Settings  (no .safetensors found in /opt/models/loras)"
            ),
            open=HAS_LORAS,
        ):
            lora_dropdown = gr.Dropdown(
                choices=LORA_LABELS if HAS_LORAS else ["None"],
                value="None",
                label="Select LoRA",
                interactive=HAS_LORAS,
            )
            lora_scale = gr.Slider(
                minimum=0.0,
                maximum=2.0,
                value=0.8,
                step=0.05,
                label="LoRA Weight",
                interactive=HAS_LORAS,
            )
            if not HAS_LORAS:
                gr.Markdown("_Drop \`.safetensors\` files into \`/opt/models/loras/\` and restart the app._")

    btn = gr.Button("Generate Video", variant="primary")
    out_video = gr.Video(label="Final video")
    downloads = gr.File(label="Downloads (final + individual clips)", file_count="multiple")
    gallery = gr.Gallery(label="Individual clips", columns=3, rows=2, height=240)
    info_box = gr.Markdown(label="Generation info")
    run_dir = gr.Textbox(label="Run directory", interactive=False)

    click_inputs = [
        prompt, negative, num_clips, seconds_per_clip, fps,
        steps, guidance, width, height,
        fade_seconds, seed, seed_mode,
    ]
    if LORA_ENABLED:
        click_inputs.extend([lora_dropdown, lora_scale])

    btn.click(
        make_video,
        click_inputs,
        [out_video, downloads, gallery, info_box, run_dir],
    )


if __name__ == "__main__":
    print(f"Video Studio starting on {BIND}:{PORT}", flush=True)
    print(f"Model: {MODEL_ID} | Device: {DEVICE} | VRAM: {VRAM_GB:.0f}GB", flush=True)
    if LORA_ENABLED:
        print(f"LoRA directory: {LORA_DIR} | files found: {len(LORA_PATHS)}", flush=True)
    demo.queue(max_size=1).launch(
        server_name=BIND,
        server_port=PORT,
        share=False,
        allowed_paths=["/root/video_runs"],
        show_error=True,
    )
PYEOF
  chmod +x "${script_path}"
}

start_video_ui() {
  local stack_name="${1:-video}"
  local script_name script_path port log_file model_source env_prefix
  script_name="$(video_ui_script_name_for_stack "${stack_name}")"
  script_path="${VIDEO_DIR}/${script_name}"
  port="$(video_port_for_stack "${stack_name}")"
  log_file="$(video_log_file_for_stack "${stack_name}")"
  model_source="$(diffusers_model_dir_for_stack "${stack_name}")"
  env_prefix=""
  [[ -f "${model_source}/model_index.json" ]] && env_prefix="MODEL_ID=\"${model_source}\" "

  if pgrep -f "${script_name}" &>/dev/null; then
    log "Video UI already running for ${stack_name}."
    return
  fi

  log "Starting ${stack_name} UI on ${BIND_ADDR}:${port}..."
  eval "${env_prefix}VIDEO_UI_HOST=\"${BIND_ADDR}\" VIDEO_UI_PORT=\"${port}\" nohup \"${VIDEO_VENV}/bin/python\" \"${script_path}\" >\"${log_file}\" 2>&1 &"
  disown
  wait_for_port "${BIND_ADDR}" "${port}" 60 5
}

# ── /onstart.sh generators ───────────────────────────────────────────────

write_onstart_text() {
  local model_path="$1"
  local ctx_size="${2:-8192}"
  write_onstart_llama_server "text" "TEXT llama.cpp" "${TEXT_PORT}" "${model_path}" "${ctx_size}"
}

write_onstart_image() {
  local model="$1"
  local model_source="$model"
  local image_loras_json_quoted
  if [[ -d "${IMAGE_MODEL_DIR}" && -f "${IMAGE_MODEL_DIR}/model_index.json" ]]; then
    model_source="${IMAGE_MODEL_DIR}"
  fi
  image_loras_json_quoted="$(python3 - <<'PY'
import os, shlex
print(shlex.quote(os.environ.get("IMAGE_LORAS_JSON", "[]")))
PY
)"
  cat > "${ONSTART}" <<ONSTART
#!/usr/bin/env bash
set -euo pipefail
mkdir -p "${LOG_DIR}"
IMAGE_LORAS_JSON=${image_loras_json_quoted}
LORA_DIR="${MODEL_DIR_BASE}/loras"

download_image_loras_onstart() {
  local entries failed=0
  local failed_names=()
  mkdir -p "\${LORA_DIR}"

  entries=\$(python3 - <<'PY'
import json
import os
from urllib.parse import urlparse

raw = os.environ.get("IMAGE_LORAS_JSON", "[]")
try:
    data = json.loads(raw)
except Exception:
    data = []

for item in data:
    if isinstance(item, str):
        url = item.strip()
        if not url:
            continue
        name = os.path.basename(urlparse(url).path) or "lora.safetensors"
        if "." not in os.path.basename(name):
            name = f"{name}.safetensors"
        print(f"{url}\t{name}")
    elif isinstance(item, dict):
        url = str(item.get("url", "")).strip()
        if not url:
            continue
        name = str(item.get("filename") or item.get("name") or os.path.basename(urlparse(url).path) or "lora.safetensors").strip()
        if name:
            if "." not in os.path.basename(name):
                name = f"{name}.safetensors"
            print(f"{url}\t{name}")
PY
)

  [[ -n "\${entries}" ]] || {
    echo "[\$(date)] No image LoRAs configured for onstart." >>"${LOG_DIR}/onstart.log"
    return 0
  }

  # Build expected filenames for cleanup
  local -a expected_files=()
  while IFS=\$'\t' read -r _url fname; do
    [[ -n "\${fname}" ]] && expected_files+=("\${fname}")
  done <<< "\${entries}"

  # Remove .safetensors not in current config
  if [[ -d "\${LORA_DIR}" ]]; then
    for existing in "\${LORA_DIR}"/*.safetensors; do
      [[ -f "\${existing}" ]] || continue
      local base
      base="\$(basename "\${existing}")"
      local keep=0
      for expected in "\${expected_files[@]}"; do
        if [[ "\${base}" == "\${expected}" ]]; then
          keep=1
          break
        fi
      done
      if [[ "\${keep}" -eq 0 ]]; then
        echo "[\$(date)] Removing obsolete LoRA: \${base}" >>"${LOG_DIR}/onstart.log"
        rm -f "\${existing}"
      fi
    done
  fi

  echo "[\$(date)] Ensuring image LoRAs in \${LORA_DIR}..." >>"${LOG_DIR}/onstart.log"
  while IFS=\$'\t' read -r url filename; do
    [[ -n "\${url}" && -n "\${filename}" ]] || continue
    local target="\${LORA_DIR}/\${filename}"
    local tmp_target="\${target}.part"
    if [[ -f "\${target}" ]]; then
      echo "[\$(date)] LoRA already present: \${filename}" >>"${LOG_DIR}/onstart.log"
      continue
    fi
    echo "[\$(date)] Downloading missing LoRA: \${filename}" >>"${LOG_DIR}/onstart.log"
    rm -f "\${tmp_target}" >/dev/null 2>&1 || true
    if curl -L --fail --retry 3 --retry-delay 5 -o "\${tmp_target}" "\${url}" >>"${LOG_DIR}/onstart.log" 2>&1; then
      mv "\${tmp_target}" "\${target}"
      echo "[\$(date)] LoRA download complete: \${filename}" >>"${LOG_DIR}/onstart.log"
    else
      rm -f "\${tmp_target}" >/dev/null 2>&1 || true
      failed=1
      failed_names+=("\${filename}")
      echo "[\$(date)] WARNING: LoRA download failed, skipping: \${filename}" >>"${LOG_DIR}/onstart.log"
    fi
  done <<< "\${entries}"

  if [[ "\${failed}" -eq 1 ]]; then
    echo "[\$(date)] WARNING: Some image LoRAs could not be downloaded: \${failed_names[*]}" >>"${LOG_DIR}/onstart.log"
  fi
}

download_image_loras_onstart
if ! pgrep -f "${APP_DIR}/app.py" &>/dev/null; then
  MODEL_ID="${model_source}" PORT="${IMAGE_PORT}" \\
    nohup "${APP_VENV}/bin/python" "${APP_DIR}/app.py" >"${LOG_DIR}/image.log" 2>&1 &
  disown
fi
echo "[\$(date)] image stack started." >>"${LOG_DIR}/onstart.log"
ONSTART
  chmod +x "${ONSTART}"
}

write_onstart_image_prompt() {
  local model="$1"
  local model_source="$model"
  local image_loras_json_quoted
  if [[ -d "${IMAGE_PROMPT_MODEL_DIR}" && -f "${IMAGE_PROMPT_MODEL_DIR}/model_index.json" ]]; then
    model_source="${IMAGE_PROMPT_MODEL_DIR}"
  fi
  image_loras_json_quoted="$(python3 - <<'PY'
import os, shlex
print(shlex.quote(os.environ.get("IMAGE_LORAS_JSON", "[]")))
PY
)"
  cat > "${ONSTART}" <<ONSTART
#!/usr/bin/env bash
set -euo pipefail
mkdir -p "${LOG_DIR}"
IMAGE_LORAS_JSON=${image_loras_json_quoted}
LORA_DIR="${MODEL_DIR_BASE}/loras"

download_image_loras_onstart() {
  local entries failed=0
  local failed_names=()
  mkdir -p "\${LORA_DIR}"

  entries=\$(python3 - <<'PY'
import json
import os
from urllib.parse import urlparse

raw = os.environ.get("IMAGE_LORAS_JSON", "[]")
try:
    data = json.loads(raw)
except Exception:
    data = []

for item in data:
    if isinstance(item, str):
        url = item.strip()
        if not url:
            continue
        name = os.path.basename(urlparse(url).path) or "lora.safetensors"
        if "." not in os.path.basename(name):
            name = f"{name}.safetensors"
        print(f"{url}\t{name}")
    elif isinstance(item, dict):
        url = str(item.get("url", "")).strip()
        if not url:
            continue
        name = str(item.get("filename") or item.get("name") or os.path.basename(urlparse(url).path) or "lora.safetensors").strip()
        if name:
            if "." not in os.path.basename(name):
                name = f"{name}.safetensors"
            print(f"{url}\t{name}")
PY
)

  [[ -n "\${entries}" ]] || {
    echo "[\$(date)] No image LoRAs configured for onstart." >>"${LOG_DIR}/onstart.log"
    return 0
  }

  local -a expected_files=()
  while IFS=\$'\t' read -r _url fname; do
    [[ -n "\${fname}" ]] && expected_files+=("\${fname}")
  done <<< "\${entries}"

  if [[ -d "\${LORA_DIR}" ]]; then
    for existing in "\${LORA_DIR}"/*.safetensors; do
      [[ -f "\${existing}" ]] || continue
      local base
      base="\$(basename "\${existing}")"
      local keep=0
      for expected in "\${expected_files[@]}"; do
        if [[ "\${base}" == "\${expected}" ]]; then
          keep=1
          break
        fi
      done
      if [[ "\${keep}" -eq 0 ]]; then
        echo "[\$(date)] Removing obsolete LoRA: \${base}" >>"${LOG_DIR}/onstart.log"
        rm -f "\${existing}"
      fi
    done
  fi

  echo "[\$(date)] Ensuring image LoRAs in \${LORA_DIR}..." >>"${LOG_DIR}/onstart.log"
  while IFS=\$'\t' read -r url filename; do
    [[ -n "\${url}" && -n "\${filename}" ]] || continue
    local target="\${LORA_DIR}/\${filename}"
    local tmp_target="\${target}.part"
    if [[ -f "\${target}" ]]; then
      echo "[\$(date)] LoRA already present: \${filename}" >>"${LOG_DIR}/onstart.log"
      continue
    fi
    echo "[\$(date)] Downloading missing LoRA: \${filename}" >>"${LOG_DIR}/onstart.log"
    rm -f "\${tmp_target}" >/dev/null 2>&1 || true
    if curl -L --fail --retry 3 --retry-delay 5 -o "\${tmp_target}" "\${url}" >>"${LOG_DIR}/onstart.log" 2>&1; then
      mv "\${tmp_target}" "\${target}"
      echo "[\$(date)] LoRA download complete: \${filename}" >>"${LOG_DIR}/onstart.log"
    else
      rm -f "\${tmp_target}" >/dev/null 2>&1 || true
      failed=1
      failed_names+=("\${filename}")
      echo "[\$(date)] WARNING: LoRA download failed, skipping: \${filename}" >>"${LOG_DIR}/onstart.log"
    fi
  done <<< "\${entries}"

  if [[ "\${failed}" -eq 1 ]]; then
    echo "[\$(date)] WARNING: Some image LoRAs could not be downloaded: \${failed_names[*]}" >>"${LOG_DIR}/onstart.log"
  fi
}

download_image_loras_onstart
if ! pgrep -f "${APP_DIR}/app_prompt.py" &>/dev/null; then
  MODEL_ID="${model_source}" PORT="${IMAGE_PROMPT_PORT:-7863}" \\
    nohup "${APP_VENV}/bin/python" "${APP_DIR}/app_prompt.py" >"${LOG_DIR}/image_prompt.log" 2>&1 &
  disown
fi
echo "[\$(date)] image_prompt stack started." >>"${LOG_DIR}/onstart.log"
ONSTART
  chmod +x "${ONSTART}"
}

write_onstart_video() {
  local stack_name="${1:-video}"
  local script_name log_file port model_source
  script_name="$(video_ui_script_name_for_stack "${stack_name}")"
  log_file="$(video_log_file_for_stack "${stack_name}")"
  port="$(video_port_for_stack "${stack_name}")"
  model_source="$(diffusers_model_dir_for_stack "${stack_name}")"
  
  local image_loras_json_quoted
  image_loras_json_quoted="$(python3 - <<'PY'
import os, shlex
print(shlex.quote(os.environ.get("IMAGE_LORAS_JSON", "[]")))
PY
)"

  cat > "${ONSTART}" <<ONSTART
#!/usr/bin/env bash
set -euo pipefail
mkdir -p "${LOG_DIR}"

IMAGE_LORAS_JSON=${image_loras_json_quoted}
LORA_DIR="${MODEL_DIR_BASE}/loras"

download_video_loras_onstart() {
  local entries failed=0
  local failed_names=()
  mkdir -p "\${LORA_DIR}"

  entries=\$(python3 - <<'PY'
import json
import os
from urllib.parse import urlparse

raw = os.environ.get("IMAGE_LORAS_JSON", "[]")
try:
    data = json.loads(raw)
except Exception:
    data = []

for item in data:
    if isinstance(item, str):
        url = item.strip()
        if not url:
            continue
        name = os.path.basename(urlparse(url).path) or "lora.safetensors"
        if "." not in os.path.basename(name):
            name = f"{name}.safetensors"
        print(f"{url}\t{name}")
    elif isinstance(item, dict):
        url = str(item.get("url", "")).strip()
        if not url:
            continue
        name = str(item.get("filename") or item.get("name") or os.path.basename(urlparse(url).path) or "lora.safetensors").strip()
        if name:
            if "." not in os.path.basename(name):
                name = f"{name}.safetensors"
            print(f"{url}\t{name}")
PY
  ) || { echo "Failed to parse IMAGE_LORAS_JSON"; return 1; }

  if [[ -z "\${entries}" ]]; then
    return 0
  fi

  local -a expected_files=()
  while IFS=\$'\\t' read -r _url fname; do
    [[ -n "\${fname}" ]] && expected_files+=("\${fname}")
  done <<< "\${entries}"

  if [[ -d "\${LORA_DIR}" ]]; then
    for existing in "\${LORA_DIR}"/*.safetensors; do
      [[ -f "\${existing}" ]] || continue
      local base
      base="\$(basename "\${existing}")"
      local keep=0
      for expected in "\${expected_files[@]}"; do
        if [[ "\${base}" == "\${expected}" ]]; then
          keep=1
          break
        fi
      done
      if [[ "\${keep}" -eq 0 ]]; then
        echo "  [cleanup] Removing obsolete LoRA: \${base}"
        rm -f "\${existing}"
      fi
    done
  fi

  echo "Downloading LoRAs..."
  while IFS=\$'\\t' read -r url filename; do
    [[ -z "\${url}" ]] && continue
    local out_path="\${LORA_DIR}/\${filename}"
    if [[ -f "\${out_path}" ]]; then
      echo "  [skip] \${filename} exists"
    else
      echo "  [dl] \${filename} from \${url}..."
      if [[ -n "\${HF_TOKEN:-}" ]]; then
        if ! curl -sSL -f -H "Authorization: Bearer \${HF_TOKEN}" "\${url}" -o "\${out_path}.tmp"; then
          echo "  [error] failed: \${filename}"
          failed=\$((failed + 1))
          failed_names+=("\${filename}")
          rm -f "\${out_path}.tmp"
        else
          mv "\${out_path}.tmp" "\${out_path}"
        fi
      else
        if ! curl -sSL -f "\${url}" -o "\${out_path}.tmp"; then
          echo "  [error] failed: \${filename}"
          failed=\$((failed + 1))
          failed_names+=("\${filename}")
          rm -f "\${out_path}.tmp"
        else
          mv "\${out_path}.tmp" "\${out_path}"
        fi
      fi
    fi
  done <<< "\${entries}"

  if [[ \${failed} -gt 0 ]]; then
    echo "Warning: \${failed} LoRAs failed to download: \${failed_names[*]}"
  fi
}

if [[ "${stack_name}" == "video_lora" ]]; then
  download_video_loras_onstart
fi

if ! pgrep -f "${script_name}" &>/dev/null; then
  if [[ -f "${model_source}/model_index.json" ]]; then
    MODEL_ID="${model_source}" VIDEO_UI_HOST="${BIND_ADDR}" VIDEO_UI_PORT="${port}" \\
      nohup "${VIDEO_VENV}/bin/python" "${VIDEO_DIR}/${script_name}" >"${log_file}" 2>&1 &
  else
    VIDEO_UI_HOST="${BIND_ADDR}" VIDEO_UI_PORT="${port}" \\
      nohup "${VIDEO_VENV}/bin/python" "${VIDEO_DIR}/${script_name}" >"${log_file}" 2>&1 &
  fi
  disown
fi
echo "[\$(date)] ${stack_name} stack started." >>"${LOG_DIR}/onstart.log"
ONSTART
  chmod +x "${ONSTART}"
}

write_onstart_comfyui() {
  local model_source
  model_source="$(diffusers_model_dir_for_stack comfyui)"

  local image_loras_json_quoted
  image_loras_json_quoted="$(python3 - <<'PY'
import os, shlex
print(shlex.quote(os.environ.get("IMAGE_LORAS_JSON", "[]")))
PY
)"

  cat > "${ONSTART}" <<ONSTART
#!/usr/bin/env bash
set -euo pipefail
mkdir -p "${LOG_DIR}"

IMAGE_LORAS_JSON=${image_loras_json_quoted}
LORA_DIR="${MODEL_DIR_BASE}/loras"

download_comfyui_loras_onstart() {
  local entries failed=0
  local failed_names=()
  mkdir -p "\${LORA_DIR}"

  entries=\$(python3 - <<'PY'
import json
import os
from urllib.parse import urlparse

raw = os.environ.get("IMAGE_LORAS_JSON", "[]")
try:
    data = json.loads(raw)
except Exception:
    data = []

for item in data:
    if isinstance(item, str):
        url = item.strip()
        if not url:
            continue
        name = os.path.basename(urlparse(url).path) or "lora.safetensors"
        if "." not in os.path.basename(name):
            name = f"{name}.safetensors"
        print(f"{url}\t{name}")
    elif isinstance(item, dict):
        url = str(item.get("url", "")).strip()
        if not url:
            continue
        name = str(item.get("filename") or item.get("name") or os.path.basename(urlparse(url).path) or "lora.safetensors").strip()
        if name:
            if "." not in os.path.basename(name):
                name = f"{name}.safetensors"
            print(f"{url}\t{name}")
PY
  ) || { echo "Failed to parse IMAGE_LORAS_JSON"; return 1; }

  if [[ -z "\${entries}" ]]; then
    return 0
  fi

  local -a expected_files=()
  while IFS=\$'\\t' read -r _url fname; do
    [[ -n "\${fname}" ]] && expected_files+=("\${fname}")
  done <<< "\${entries}"

  if [[ -d "\${LORA_DIR}" ]]; then
    for existing in "\${LORA_DIR}"/*.safetensors; do
      [[ -f "\${existing}" ]] || continue
      local base
      base="\$(basename "\${existing}")"
      local keep=0
      for expected in "\${expected_files[@]}"; do
        if [[ "\${base}" == "\${expected}" ]]; then
          keep=1
          break
        fi
      done
      if [[ "\${keep}" -eq 0 ]]; then
        echo "  [cleanup] Removing obsolete LoRA: \${base}"
        rm -f "\${existing}"
      fi
    done
  fi

  echo "Downloading LoRAs..."
  while IFS=\$'\\t' read -r url filename; do
    [[ -z "\${url}" ]] && continue
    local out_path="\${LORA_DIR}/\${filename}"
    if [[ -f "\${out_path}" ]]; then
      echo "  [skip] \${filename} exists"
    else
      echo "  [dl] \${filename} from \${url}..."
      if [[ -n "\${HF_TOKEN:-}" ]]; then
        if ! curl -sSL -f -H "Authorization: Bearer \${HF_TOKEN}" "\${url}" -o "\${out_path}.tmp"; then
          echo "  [error] failed: \${filename}"
          failed=\$((failed + 1))
          failed_names+=("\${filename}")
          rm -f "\${out_path}.tmp"
        else
          mv "\${out_path}.tmp" "\${out_path}"
        fi
      else
        if ! curl -sSL -f "\${url}" -o "\${out_path}.tmp"; then
          echo "  [error] failed: \${filename}"
          failed=\$((failed + 1))
          failed_names+=("\${filename}")
          rm -f "\${out_path}.tmp"
        else
          mv "\${out_path}.tmp" "\${out_path}"
        fi
      fi
    fi
  done <<< "\${entries}"

  if [[ \${failed} -gt 0 ]]; then
    echo "Warning: \${failed} LoRAs failed to download: \${failed_names[*]}"
  fi
}

download_comfyui_loras_onstart

if ! pgrep -f "main.py.*--listen" &>/dev/null; then
  if [[ -f "${model_source}/model_index.json" ]]; then
    MODEL_PATH="${model_source}" \\
      nohup "${COMFYUI_VENV}/bin/python" "${COMFYUI_DIR}/ComfyUI/main.py" \\
        --listen "${BIND_ADDR}" \\
        --port "${COMFYUI_PORT}" \\
        --output-directory "${COMFYUI_DIR}/output" \\
        --temp-directory "${COMFYUI_DIR}/temp" \\
        --input-directory "${COMFYUI_DIR}/input" \\
        --disable-auto-launch \\
        >"${LOG_DIR}/comfyui.log" 2>&1 &
  else
    nohup "${COMFYUI_VENV}/bin/python" "${COMFYUI_DIR}/ComfyUI/main.py" \\
      --listen "${BIND_ADDR}" \\
      --port "${COMFYUI_PORT}" \\
      --output-directory "${COMFYUI_DIR}/output" \\
      --temp-directory "${COMFYUI_DIR}/temp" \\
      --input-directory "${COMFYUI_DIR}/input" \\
      --disable-auto-launch \\
      >"${LOG_DIR}/comfyui.log" 2>&1 &
  fi
  disown
fi
echo "[\$(date)] comfyui stack started." >>"${LOG_DIR}/onstart.log"
ONSTART
  chmod +x "${ONSTART}"
}

# ── Print info ────────────────────────────────────────────────────────────

write_manifest() {
  local stack="$1"
  local template="$2"
  local service_port="$3"
  
  cat > /etc/stack_manifest.json <<MANIFEST
{
  "manifest_version": 1,
  "stack": "${stack}",
  "template": "${template}",
  "service_port": ${service_port},
  "model": "${STACK_MODEL}",
  "model_file_hint": "${STACK_MODEL_FILE_HINT}",
  "created_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
MANIFEST
  log "Manifest geschrieben: /etc/stack_manifest.json"
}

print_info() {
  cat <<EOF

╔══════════════════════════════════════════════════════════════╗
║  ✓ Stack Ready!                                              ║
╠══════════════════════════════════════════════════════════════╣
║  Type : ${STACK_TYPE}                                        ║
║  Model: ${STACK_MODEL}                                       ║
║  Bind : ${BIND_ADDR} (SSH tunnel only)                       ║
╠══════════════════════════════════════════════════════════════╣
║  Logs:   tail -f ${LOG_DIR}/*.log                            ║
║  Restart: bash /onstart.sh                                   ║
║  Manifest: cat /etc/stack_manifest.json                      ║
║                                                              ║
║  Commands from host:                                         ║
║    ./manage_v7_fixed.sh start ${STACK_TYPE}                  ║
║    ./manage_v7_fixed.sh login ${STACK_TYPE}                  ║
║    python3 vast.py health ${STACK_TYPE} --json               ║
╚══════════════════════════════════════════════════════════════╝
EOF
}

# ── Main ──────────────────────────────────────────────────────────────────

acquire_lock
install_deps_common

case "${STACK_TYPE}" in
  text)
    STACK_MODEL="${STACK_MODEL:-$TEXT_DEFAULT_MODEL}"
    STACK_TEMPLATE="${STACK_TEMPLATE:-nvidia/cuda:12.4.1-cudnn-devel-ubuntu22.04}"
    SERVICE_PORT="${SERVICE_PORT:-8080}"
    install_llama_cpp
    install_hf_hub
    text_model_path="$(resolve_gguf_model_path "${STACK_MODEL}" "${STACK_MODEL_FILE_HINT}" "text")"
    write_onstart_text "${text_model_path}" 8192
    start_llama_server "text" "TEXT llama.cpp" "${TEXT_PORT}" "${text_model_path}" 8192
    write_manifest "text" "${STACK_TEMPLATE}" "${SERVICE_PORT}"
    ;;
  text_pro)
    # Requires H100 or better GPU
    require_h100_gpu || exit 1
    STACK_MODEL="${STACK_MODEL:-$TEXT_PRO_DEFAULT_MODEL}"
    STACK_TEMPLATE="${STACK_TEMPLATE:-nvidia/cuda:12.4.1-cudnn-devel-ubuntu22.04}"
    SERVICE_PORT="${SERVICE_PORT:-8081}"
    install_llama_cpp
    install_hf_hub
    text_pro_model_path="$(resolve_gguf_model_path "${STACK_MODEL}" "${STACK_MODEL_FILE_HINT}" "text_pro")"
    write_onstart_text_pro "${text_pro_model_path}" 16384
    start_llama_server "text_pro" "TEXT_PRO llama.cpp" "${TEXT_PRO_PORT}" "${text_pro_model_path}" 16384
    write_manifest "text_pro" "${STACK_TEMPLATE}" "${SERVICE_PORT}"
    log "TEXT_PRO llama.cpp stack ready on port ${TEXT_PRO_PORT}"
    ;;
  image)
    STACK_MODEL="${STACK_MODEL:-$IMAGE_DEFAULT_MODEL}"
    STACK_TEMPLATE="${STACK_TEMPLATE:-nvidia/cuda:12.4.1-cudnn-devel-ubuntu22.04}"
    SERVICE_PORT="${SERVICE_PORT:-7860}"
    install_image_env
    download_image_loras
    write_image_app_py
    pull_hf_model "${STACK_MODEL}"
    start_image_ui "${STACK_MODEL}"
    write_onstart_image "${STACK_MODEL}"
    write_manifest "image" "${STACK_TEMPLATE}" "${SERVICE_PORT}"
    ;;
  image_prompt)
    STACK_MODEL="${STACK_MODEL:-$IMAGE_PROMPT_DEFAULT_MODEL}"
    STACK_TEMPLATE="${STACK_TEMPLATE:-nvidia/cuda:12.4.1-cudnn-devel-ubuntu22.04}"
    SERVICE_PORT="${SERVICE_PORT:-7863}"
    install_image_prompt_env
    download_image_loras
    write_image_prompt_app_py
    pull_hf_model "${STACK_MODEL}"
    start_image_prompt_ui "${STACK_MODEL}"
    write_onstart_image_prompt "${STACK_MODEL}"
    write_manifest "image_prompt" "${STACK_TEMPLATE}" "${SERVICE_PORT}"
    ;;
  video)
    STACK_MODEL="${STACK_MODEL:-$VIDEO_DEFAULT_MODEL}"
    STACK_TEMPLATE="${STACK_TEMPLATE:-nvidia/cuda:12.4.1-cudnn-devel-ubuntu22.04}"
    SERVICE_PORT="${SERVICE_PORT:-7861}"
    install_video_env
    write_video_ui "${STACK_MODEL}" "video"
    pull_video_model "${STACK_MODEL}"
    start_video_ui "video"
    write_onstart_video "video"
    write_manifest "video" "${STACK_TEMPLATE}" "${SERVICE_PORT}"
    ;;
  video_lora)
    STACK_MODEL="${STACK_MODEL:-$VIDEO_LORA_DEFAULT_MODEL}"
    STACK_TEMPLATE="${STACK_TEMPLATE:-nvidia/cuda:12.4.1-cudnn-devel-ubuntu22.04}"
    SERVICE_PORT="${SERVICE_PORT:-7862}"
    install_video_env
    write_video_ui "${STACK_MODEL}" "video_lora"
    pull_video_model "${STACK_MODEL}"
    start_video_ui "video_lora"
    write_onstart_video "video_lora"
    write_manifest "video_lora" "${STACK_TEMPLATE}" "${SERVICE_PORT}"
    ;;
  video_i2v)
    STACK_MODEL="${STACK_MODEL:-$VIDEO_I2V_DEFAULT_MODEL}"
    STACK_TEMPLATE="${STACK_TEMPLATE:-nvidia/cuda:12.4.1-cudnn-devel-ubuntu22.04}"
    SERVICE_PORT="${SERVICE_PORT:-7861}"
    install_video_env
    write_video_i2v_py "${STACK_MODEL}"
    pull_video_i2v_model "${STACK_MODEL}"
    write_manifest "video_i2v" "${STACK_TEMPLATE}" "${SERVICE_PORT}"
    ;;
  comfyui)
    STACK_MODEL="${STACK_MODEL:-$COMFYUI_DEFAULT_MODEL}"
    STACK_TEMPLATE="${STACK_TEMPLATE:-nvidia/cuda:12.4.1-cudnn-devel-ubuntu22.04}"
    SERVICE_PORT="${SERVICE_PORT:-7867}"
    install_comfyui_env
    write_start_comfyui_script
    pull_hf_model "${STACK_MODEL}"
    start_comfyui_ui "${STACK_MODEL}"
    write_onstart_comfyui
    write_manifest "comfyui" "${STACK_TEMPLATE}" "${SERVICE_PORT}"
    ;;
  *) echo "Unknown STACK_TYPE: ${STACK_TYPE}"; exit 1;;
esac

print_info
