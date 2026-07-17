#!/bin/bash

# Move the GitLab virtual LAN address between one AlmaLinux host and one macOS
# host. Run activate on exactly one host at a time; it deliberately refuses to
# claim an address that another device answers for.

set -euo pipefail
[[ -n "${TRACE:-}" ]] && set -x

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
GITLAB_ENV_FILE="${GITLAB_ENV_FILE:-${PROJECT_ROOT}/.gitlab.env}"
if [[ -f "${GITLAB_ENV_FILE}" ]]; then
  # shellcheck disable=SC1090
  source "${GITLAB_ENV_FILE}"
fi

VIP="${GITLAB_EXTERNAL_IP:-192.168.86.50}"
PREFIX_LENGTH="${GITLAB_VIP_PREFIX_LENGTH:-24}"
VIP_CIDR="${VIP}/${PREFIX_LENGTH}"
GITLAB_DOMAIN="${GITLAB_DOMAIN:-${VIP}.nip.io}"
GITLAB_HOST="${GITLAB_HOST:-gitlab.${GITLAB_DOMAIN}}"
GITLAB_URL="${GITLAB_URL:-https://${GITLAB_HOST}/users/sign_in}"
VERIFY_TIMEOUT_SECONDS="${GITLAB_VIP_VERIFY_TIMEOUT_SECONDS:-30}"
ACTION="${1:-}"

if [[ "${PREFIX_LENGTH}" != "24" ]]; then
  echo "ERROR: gitlab-vip.sh currently supports an IPv4 /24 LAN only." >&2
  exit 2
fi

usage() {
  cat <<EOF
Usage: bash scripts/gitlab-vip.sh <activate|deactivate|status|verify>

Manage the GitLab virtual LAN address (${VIP}) on this host.

Run deactivate on the current active host before activate on the replacement.
The script only manages the network address; stop/start GitLab and restore its
backup separately. Run verify after GitLab is started on the replacement. It
checks the HTTPS endpoint through the VIP and then announces the move on the
LAN. Override the address with GITLAB_EXTERNAL_IP.
EOF
}

case "${ACTION}" in
  activate|deactivate|status|verify) ;;
  -h|--help|help|'') usage; exit 0 ;;
  *) echo "ERROR: unknown action '${ACTION}'." >&2; usage >&2; exit 2 ;;
esac

OS="$(uname -s)"

case "${OS}" in
  Linux)
    command -v ip > /dev/null || { echo "ERROR: iproute is required." >&2; exit 1; }
    INTERFACE="${GITLAB_VIP_INTERFACE:-$(ip route get 1.1.1.1 | awk '/dev/ { for (i = 1; i <= NF; i++) if ($i == "dev") { print $(i + 1); exit } }')}"
    ;;
  Darwin)
    INTERFACE="${GITLAB_VIP_INTERFACE:-$(route -n get default 2>/dev/null | awk '/interface:/{print $2; exit}')}"
    ;;
  *) echo "ERROR: unsupported operating system '${OS}'." >&2; exit 1 ;;
esac

[[ -n "${INTERFACE}" ]] || { echo "ERROR: could not determine the LAN interface; set GITLAB_VIP_INTERFACE." >&2; exit 1; }

address_is_local() {
  case "${OS}" in
    Linux) ip -o -4 addr show dev "${INTERFACE}" | awk '{print $4}' | cut -d/ -f1 | grep -Fxq "${VIP}" ;;
    Darwin) ifconfig "${INTERFACE}" | awk '/inet / {print $2}' | grep -Fxq "${VIP}" ;;
  esac
}

address_is_in_use() {
  if command -v arping > /dev/null 2>&1; then
    # arping -D returns success only when no other machine replies.
    ! sudo arping -D -I "${INTERFACE}" -c 3 "${VIP}" > /dev/null 2>&1
  else
    # This is only a fallback: hosts may reject ICMP. macOS interprets -W in
    # milliseconds, while Linux interprets it in seconds.
    case "${OS}" in
      Linux) ping -c 1 -W 1 "${VIP}" > /dev/null 2>&1 ;;
      Darwin) ping -c 1 -W 1000 "${VIP}" > /dev/null 2>&1 ;;
    esac
  fi
}

announce_vip() {
  if ! command -v arping > /dev/null 2>&1; then
    echo "WARNING: arping is unavailable; cannot send a gratuitous ARP announcement." >&2
    return 0
  fi

  # Tell neighboring devices immediately that this host now owns the address.
  sudo arping -U -I "${INTERFACE}" -c 3 "${VIP}" > /dev/null
  echo "Announced GitLab virtual IP ${VIP} on the LAN."
}

verify() {
  if ! address_is_local; then
    echo "ERROR: GitLab virtual IP ${VIP} is not active on ${INTERFACE}." >&2
    return 1
  fi
  command -v curl > /dev/null || { echo "ERROR: curl is required for verification." >&2; return 1; }
  command -v nc > /dev/null || { echo "ERROR: nc is required to verify GitLab SSH." >&2; return 1; }
  [[ "${VERIFY_TIMEOUT_SECONDS}" =~ ^[1-9][0-9]*$ ]] || {
    echo "ERROR: GITLAB_VIP_VERIFY_TIMEOUT_SECONDS must be a positive integer." >&2
    return 1
  }

  echo "Checking GitLab HTTPS and SSH through ${VIP} (up to ${VERIFY_TIMEOUT_SECONDS}s)..."
  local deadline=$((SECONDS + VERIFY_TIMEOUT_SECONDS))
  until curl --fail --silent --show-error --head \
      --connect-timeout 5 --max-time 10 \
      --resolve "${GITLAB_HOST}:443:${VIP}" "${GITLAB_URL}" > /dev/null \
      && nc -z -w 5 "${VIP}" 2222; do
    if (( SECONDS >= deadline )); then
      echo "ERROR: GitLab HTTPS or SSH did not become healthy through VIP ${VIP}." >&2
      return 1
    fi
    sleep 2
  done

  echo "GitLab HTTPS and SSH are healthy through VIP ${VIP}."
  announce_vip
}

linux_connection_uuid() {
  nmcli -g GENERAL.CON-UUID device show "${INTERFACE}" | head -n 1
}

status() {
  echo "GitLab virtual IP: ${VIP_CIDR}"
  echo "Interface: ${INTERFACE} (${OS})"
  if address_is_local; then
    echo "Status: active on this host"
  elif address_is_in_use; then
    echo "Status: active on another device"
  else
    echo "Status: unclaimed"
  fi
}

activate_linux() {
  command -v nmcli > /dev/null || { echo "ERROR: NetworkManager (nmcli) is required on Linux." >&2; exit 1; }
  local connection_uuid
  connection_uuid="$(linux_connection_uuid)"
  [[ -n "${connection_uuid}" && "${connection_uuid}" != "--" ]] || { echo "ERROR: '${INTERFACE}' has no active NetworkManager connection." >&2; exit 1; }
  sudo nmcli connection modify uuid "${connection_uuid}" +ipv4.addresses "${VIP_CIDR}"
  sudo nmcli device reapply "${INTERFACE}"
}

deactivate_linux() {
  command -v nmcli > /dev/null || { echo "ERROR: NetworkManager (nmcli) is required on Linux." >&2; exit 1; }
  local connection_uuid
  connection_uuid="$(linux_connection_uuid)"
  [[ -n "${connection_uuid}" && "${connection_uuid}" != "--" ]] || { echo "ERROR: '${INTERFACE}' has no active NetworkManager connection." >&2; exit 1; }
  sudo nmcli connection modify uuid "${connection_uuid}" -ipv4.addresses "${VIP_CIDR}"
  sudo nmcli device reapply "${INTERFACE}"
}

case "${ACTION}" in
  status)
    status
    ;;
  verify)
    verify
    ;;
  activate)
    if address_is_local; then
      echo "GitLab virtual IP ${VIP} is already active on ${INTERFACE}."
      exit 0
    fi
    if address_is_in_use; then
      echo "ERROR: ${VIP} is in use by another device. Deactivate it there before retrying." >&2
      exit 1
    fi
    case "${OS}" in
      Linux) activate_linux ;;
      Darwin) sudo ifconfig "${INTERFACE}" alias "${VIP}" netmask 255.255.255.0 ;;
    esac
    echo "Activated GitLab virtual IP ${VIP} on ${INTERFACE}."
    ;;
  deactivate)
    if ! address_is_local; then
      echo "GitLab virtual IP ${VIP} is not active on ${INTERFACE}."
      exit 0
    fi
    case "${OS}" in
      Linux) deactivate_linux ;;
      Darwin) sudo ifconfig "${INTERFACE}" -alias "${VIP}" ;;
    esac
    echo "Deactivated GitLab virtual IP ${VIP} on ${INTERFACE}."
    ;;
esac
