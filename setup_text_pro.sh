#!/usr/bin/env bash
# setup_text_pro.sh - legacy wrapper for the unified llama.cpp-based remote setup
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REMOTE_SETUP="${SCRIPT_DIR}/setup_remote_v3.sh"
STACKS_YAML="${SCRIPT_DIR}/stacks.yaml"

[[ -f "${REMOTE_SETUP}" ]] || {
  echo "setup_remote_v3.sh not found next to setup_text_pro.sh" >&2
  exit 1
}

MODEL_REPO="${STACK_MODEL:-}"
MODEL_FILE_HINT="${STACK_MODEL_FILE_HINT:-}"

if [[ -f "${STACKS_YAML}" ]]; then
  [[ -n "${MODEL_REPO}" ]] || MODEL_REPO="$(python3 -c "import yaml; c=yaml.safe_load(open('${STACKS_YAML}')); print(c.get('stacks', {}).get('text_pro', {}).get('default_model', ''))")"
  [[ -n "${MODEL_FILE_HINT}" ]] || MODEL_FILE_HINT="$(python3 -c "import yaml; c=yaml.safe_load(open('${STACKS_YAML}')); print(c.get('stacks', {}).get('text_pro', {}).get('model_file_hint', ''))")"
fi

exec env STACK_TYPE=text_pro STACK_MODEL="${MODEL_REPO}" STACK_MODEL_FILE_HINT="${MODEL_FILE_HINT}" "${REMOTE_SETUP}" "$@"
