#!/bin/bash

# Publish the local k3d GitLab ports on the dedicated LAN address configured
# in .gitlab.env. This is needed on macOS because Docker Desktop does not
# expose published ports through secondary interface aliases.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
GITLAB_ENV_FILE="${GITLAB_ENV_FILE:-${PROJECT_ROOT}/.gitlab.env}"

if [[ ! -f "${GITLAB_ENV_FILE}" ]]; then
  echo "ERROR: ${GITLAB_ENV_FILE} is required."
  exit 1
fi

# shellcheck disable=SC1090
source "${GITLAB_ENV_FILE}"

: "${GITLAB_EXTERNAL_IP:?GITLAB_EXTERNAL_IP must be set in .gitlab.env}"
INTERFACE="${GITLAB_VIP_INTERFACE:-en0}"

if ! /sbin/ifconfig "${INTERFACE}" | /usr/bin/grep -Fq "inet ${GITLAB_EXTERNAL_IP} "; then
  /sbin/ifconfig "${INTERFACE}" alias "${GITLAB_EXTERNAL_IP}" netmask 255.255.255.0
fi

# macOS does not reliably hairpin traffic from this host to a secondary LAN
# alias. Keep local browser access on the same hostname by routing only this
# host's requests to Docker Desktop's loopback listener.
/sbin/route -n add -host "${GITLAB_EXTERNAL_IP}" -interface lo0 2>/dev/null || true

for port in 80 443; do
  /usr/local/bin/socat \
    "TCP4-LISTEN:${port},bind=${GITLAB_EXTERNAL_IP},fork,reuseaddr" \
    "TCP4:127.0.0.1:${port},bind=127.0.0.1" &
done

exec /usr/local/bin/socat \
  "TCP4-LISTEN:2222,bind=${GITLAB_EXTERNAL_IP},fork,reuseaddr" \
  "TCP4:127.0.0.1:2222,bind=127.0.0.1"
