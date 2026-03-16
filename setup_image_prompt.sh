#!/usr/bin/env bash
# setup_image_prompt.sh - wrapper for the FLUX.2 Text-to-Image setup
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REMOTE_SETUP="${SCRIPT_DIR}/setup_remote_v3.sh"
STACKS_YAML="${SCRIPT_DIR}/stacks.yaml"

[[ -f "${REMOTE_SETUP}" ]] || {
  echo "setup_remote_v3.sh not found next to setup_image_prompt.sh" >&2
  exit 1
}

MODEL_REPO="${STACK_MODEL:-}"

if [[ -f "${STACKS_YAML}" ]]; then
  [[ -n "${MODEL_REPO}" ]] || MODEL_REPO="$(python3 -c "import yaml; c=yaml.safe_load(open('${STACKS_YAML}')); print(c.get('stacks', {}).get('image_prompt', {}).get('default_model', ''))")"
fi

exec env STACK_TYPE=image_prompt STACK_MODEL="${MODEL_REPO}" "${REMOTE_SETUP}" "$@"
