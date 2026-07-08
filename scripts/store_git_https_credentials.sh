#!/bin/bash

# Store the repo-local glab OAuth token where plain Git HTTPS can use it.

set -eo pipefail
[[ "${TRACE}" ]] && set -x

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CODE_ROOT="$(cd "${PROJECT_ROOT}/.." && pwd)"

GITLAB_HOST="${GITLAB_HOST:-gitlab.127.0.0.1.nip.io}"
GITLAB_HTTPS_URL="${GITLAB_HTTPS_URL:-https://${GITLAB_HOST}}"
GLAB_CONFIG_FILE="${GLAB_CONFIG_FILE:-${CODE_ROOT}/.glab-config/glab-cli/config.yml}"

function require_command() {
  local command_name="$1"

  if ! command -v "${command_name}" > /dev/null 2>&1; then
    echo "ERROR: ${command_name} is required but was not found."
    exit 1
  fi
}

function glab_token() {
  awk -v host="${GITLAB_HOST}" '
    $1 == host ":" { inhost = 1; next }
    inhost && $1 == "token:" { print $2; exit }
  ' "${GLAB_CONFIG_FILE}"
}

function ensure_global_config_value() {
  local key="$1"
  local value="$2"

  if git config --global --get-all "${key}" | grep -Fxq "${value}"; then
    return 0
  fi

  git config --global --add "${key}" "${value}"
}

if [[ ! -f "${GLAB_CONFIG_FILE}" ]]; then
  echo "ERROR: glab config was not found: ${GLAB_CONFIG_FILE}"
  echo "Run glab auth login first from ${PROJECT_ROOT}."
  exit 1
fi

TOKEN="$(glab_token)"
if [[ -z "${TOKEN}" ]]; then
  echo "ERROR: No token found for ${GITLAB_HOST} in ${GLAB_CONFIG_FILE}."
  echo "Run glab auth login first from ${PROJECT_ROOT}."
  exit 1
fi

case "$(uname -s)" in
  Darwin)
    require_command git
    ;;
  Linux)
    require_command git
    git config --global credential.helper store
    ;;
  *)
    echo "ERROR: Unsupported OS: $(uname -s)"
    echo "Supported: macOS and Linux."
    exit 1
    ;;
esac

printf "protocol=https\nhost=%s\nusername=oauth2\npassword=%s\n\n" "${GITLAB_HOST}" "${TOKEN}" \
  | git credential approve

git config --global "credential.${GITLAB_HTTPS_URL}.username" oauth2
ensure_global_config_value "url.${GITLAB_HTTPS_URL}/.insteadOf" "git@${GITLAB_HOST}:"
ensure_global_config_value "url.${GITLAB_HTTPS_URL}/.insteadOf" "ssh://git@${GITLAB_HOST}/"

if [[ "$(uname -s)" == "Linux" && -f "${HOME}/.git-credentials" ]]; then
  chmod 600 "${HOME}/.git-credentials"
fi

echo "Stored Git HTTPS credentials for ${GITLAB_HOST}."
echo "Configured Git to use oauth2 and rewrite local GitLab SSH URLs to HTTPS."
echo "Check:"
printf "protocol=https\nhost=%s\nusername=oauth2\n\n" "${GITLAB_HOST}" \
  | git credential fill \
  | awk -F= '
      $1 == "username" { print }
      $1 == "password" { print "password=<redacted>" }
    '
