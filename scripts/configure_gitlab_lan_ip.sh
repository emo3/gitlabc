#!/bin/bash

# Persist the GitLab LAN address as a secondary IPv4 address on the active
# NetworkManager connection. Safe to rerun: it only adds the address when it
# is absent from that connection.

set -euo pipefail
[[ -n "${TRACE:-}" ]] && set -x

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
GITLAB_ENV_FILE="${GITLAB_ENV_FILE:-${PROJECT_ROOT}/.gitlab.env}"
if [[ -f "${GITLAB_ENV_FILE}" ]]; then
  # shellcheck disable=SC1090
  source "${GITLAB_ENV_FILE}"
fi

GITLAB_EXTERNAL_IP="${GITLAB_EXTERNAL_IP:-192.168.86.50}"
GITLAB_LAN_PREFIX="${GITLAB_LAN_PREFIX:-24}"
GITLAB_LAN_DEVICE="${GITLAB_LAN_DEVICE:-}"
GITLAB_LAN_CONNECTION="${GITLAB_LAN_CONNECTION:-}"

function usage() {
  cat <<'EOF'
Usage: bash scripts/configure_gitlab_lan_ip.sh

Adds GITLAB_EXTERNAL_IP as a permanent secondary IPv4 address to the active
NetworkManager connection, after checking it is unused on the LAN.

Optional environment variables:
  GITLAB_EXTERNAL_IP       Address to add (default: 192.168.86.50)
  GITLAB_LAN_PREFIX        CIDR prefix length (default: 24)
  GITLAB_LAN_DEVICE        Network device; defaults to the default-route device
  GITLAB_LAN_CONNECTION    Active NetworkManager connection; inferred from device

The address must be reserved in DHCP or otherwise allocated to this host.
EOF
}

case "${1:-}" in
  -h|--help)
    usage
    exit 0
    ;;
  '')
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac

function require_tool() {
  if ! command -v "$1" > /dev/null 2>&1; then
    echo "ERROR: $1 is required but not installed." >&2
    exit 1
  fi
}

function valid_ipv4() {
  local value="$1"
  local part
  local -a parts

  IFS=. read -r -a parts <<< "${value}"
  [[ "${#parts[@]}" -eq 4 ]] || return 1
  for part in "${parts[@]}"; do
    [[ "${part}" =~ ^[0-9]+$ ]] && ((10#${part} <= 255)) || return 1
  done
}

function address_is_local() {
  ip -o -4 address show | awk '{print $4}' | cut -d/ -f1 |
    grep -Fqx "${GITLAB_EXTERNAL_IP}"
}

function address_is_on_device() {
  ip -o -4 address show dev "${GITLAB_LAN_DEVICE}" | awk '{print $4}' |
    cut -d/ -f1 | grep -Fqx "${GITLAB_EXTERNAL_IP}"
}

function connection_has_address() {
  nmcli -g ipv4.addresses connection show "${GITLAB_LAN_CONNECTION}" |
    tr ',' '\n' | cut -d/ -f1 | grep -Fqx "${GITLAB_EXTERNAL_IP}"
}

function apply_address_now() {
  if address_is_on_device; then
    return
  fi

  # `reapply` does not update every IPv4 setting on every NetworkManager
  # version. A device modification applies the saved address without
  # reconnecting Wi-Fi; use iproute2 only if NetworkManager cannot do that.
  sudo nmcli device modify "${GITLAB_LAN_DEVICE}" \
    +ipv4.addresses "${GITLAB_EXTERNAL_IP}/${GITLAB_LAN_PREFIX}" || true
  if ! address_is_on_device; then
    sudo ip address add "${GITLAB_EXTERNAL_IP}/${GITLAB_LAN_PREFIX}" \
      dev "${GITLAB_LAN_DEVICE}"
  fi
}

require_tool ip
require_tool nmcli

if ! valid_ipv4 "${GITLAB_EXTERNAL_IP}"; then
  echo "ERROR: GITLAB_EXTERNAL_IP must be an IPv4 address: ${GITLAB_EXTERNAL_IP}" >&2
  exit 2
fi
if ! [[ "${GITLAB_LAN_PREFIX}" =~ ^[0-9]+$ ]] || ((GITLAB_LAN_PREFIX > 32)); then
  echo "ERROR: GITLAB_LAN_PREFIX must be an integer from 0 through 32." >&2
  exit 2
fi

if [[ -z "${GITLAB_LAN_DEVICE}" ]]; then
  GITLAB_LAN_DEVICE="$(ip route show default | awk 'NR == 1 {print $5}')"
fi
if [[ -z "${GITLAB_LAN_DEVICE}" ]]; then
  echo "ERROR: Could not determine the default-route device. Set GITLAB_LAN_DEVICE." >&2
  exit 1
fi

if [[ -z "${GITLAB_LAN_CONNECTION}" ]]; then
  GITLAB_LAN_CONNECTION="$(nmcli -g GENERAL.CONNECTION device show "${GITLAB_LAN_DEVICE}")"
fi
if [[ -z "${GITLAB_LAN_CONNECTION}" || "${GITLAB_LAN_CONNECTION}" == "--" ]]; then
  echo "ERROR: No active NetworkManager connection for ${GITLAB_LAN_DEVICE}. Set GITLAB_LAN_CONNECTION." >&2
  exit 1
fi

if ! nmcli connection show "${GITLAB_LAN_CONNECTION}" > /dev/null 2>&1; then
  echo "ERROR: NetworkManager connection not found: ${GITLAB_LAN_CONNECTION}" >&2
  exit 1
fi

if connection_has_address; then
  echo "GitLab address ${GITLAB_EXTERNAL_IP}/${GITLAB_LAN_PREFIX} is already persistent on '${GITLAB_LAN_CONNECTION}'."
elif address_is_local; then
  echo "GitLab address ${GITLAB_EXTERNAL_IP} is already assigned locally; making it persistent on '${GITLAB_LAN_CONNECTION}'."
  sudo nmcli connection modify "${GITLAB_LAN_CONNECTION}" \
    +ipv4.addresses "${GITLAB_EXTERNAL_IP}/${GITLAB_LAN_PREFIX}"
else
  require_tool arping
  echo "Checking that ${GITLAB_EXTERNAL_IP} is unused on ${GITLAB_LAN_DEVICE}..."
  if ! sudo arping -D -c 3 -I "${GITLAB_LAN_DEVICE}" "${GITLAB_EXTERNAL_IP}"; then
    echo "ERROR: ${GITLAB_EXTERNAL_IP} appears to be in use; no changes were made." >&2
    exit 1
  fi
  sudo nmcli connection modify "${GITLAB_LAN_CONNECTION}" \
    +ipv4.addresses "${GITLAB_EXTERNAL_IP}/${GITLAB_LAN_PREFIX}"
  echo "Added ${GITLAB_EXTERNAL_IP}/${GITLAB_LAN_PREFIX} to '${GITLAB_LAN_CONNECTION}'."
fi

sudo nmcli device reapply "${GITLAB_LAN_DEVICE}"
apply_address_now
if ! address_is_on_device; then
  echo "ERROR: ${GITLAB_EXTERNAL_IP} was not assigned after reapplying ${GITLAB_LAN_DEVICE}." >&2
  exit 1
fi

echo "GitLab LAN address is ready on ${GITLAB_LAN_DEVICE} (${GITLAB_LAN_CONNECTION})."
