#!/bin/bash

# Add the local SSH public key to the repo-local GitLab account if needed.

set -eo pipefail
[[ "${TRACE}" ]] && set -x

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CODE_ROOT="$(cd "${PROJECT_ROOT}/.." && pwd)"

GITLAB_ENV_FILE="${GITLAB_ENV_FILE:-${PROJECT_ROOT}/.gitlab.env}"
if [[ -f "${GITLAB_ENV_FILE}" ]]; then
  # shellcheck disable=SC1090
  source "${GITLAB_ENV_FILE}"
fi
GITLAB_DOMAIN="${GITLAB_DOMAIN:-127.0.0.1.nip.io}"
GITLAB_HOST="${GITLAB_HOST:-gitlab.${GITLAB_DOMAIN}}"
XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-${CODE_ROOT}/.glab-config}"
SSH_PUBLIC_KEY_FILE="${SSH_PUBLIC_KEY_FILE:-${HOME}/.ssh/id_ed25519.pub}"
SSH_KEY_TITLE="${SSH_KEY_TITLE:-$(hostname -s)-$(basename "${SSH_PUBLIC_KEY_FILE}")}"

function require_command() {
  local command_name="$1"

  if ! command -v "${command_name}" > /dev/null 2>&1; then
    echo "ERROR: ${command_name} is required but was not found."
    exit 1
  fi
}

require_command glab
require_command jq

if [[ ! -f "${SSH_PUBLIC_KEY_FILE}" ]]; then
  echo "ERROR: SSH public key was not found: ${SSH_PUBLIC_KEY_FILE}"
  exit 1
fi

PUBLIC_KEY="$(sed -n '1p' "${SSH_PUBLIC_KEY_FILE}")"
if [[ -z "${PUBLIC_KEY}" ]]; then
  echo "ERROR: SSH public key file is empty: ${SSH_PUBLIC_KEY_FILE}"
  exit 1
fi

KEYS_JSON="$(XDG_CONFIG_HOME="${XDG_CONFIG_HOME}" glab api --hostname "${GITLAB_HOST}" user/keys)"
if jq -e --arg key "${PUBLIC_KEY}" '.[] | select(.key == $key)' >/dev/null <<< "${KEYS_JSON}"; then
  echo "SSH key already exists in GitLab for ${GITLAB_HOST}: ${SSH_PUBLIC_KEY_FILE}"
  exit 0
fi

XDG_CONFIG_HOME="${XDG_CONFIG_HOME}" glab api \
  --hostname "${GITLAB_HOST}" \
  --method POST \
  user/keys \
  --raw-field "title=${SSH_KEY_TITLE}" \
  --raw-field "key=${PUBLIC_KEY}" \
  --silent

echo "Added SSH key to GitLab for ${GITLAB_HOST}: ${SSH_PUBLIC_KEY_FILE}"
