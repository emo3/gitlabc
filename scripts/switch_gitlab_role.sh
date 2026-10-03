#!/bin/bash

# Promote the standby GitLab host only after fencing the active host. The
# shared GitLab endpoint is removed from the old host before the new host
# claims it, preventing two hosts from advertising the same address.

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
GITLAB_PRIMARY_HOST="${GITLAB_PRIMARY_HOST:-almalinxo}"
GITLAB_STANDBY_HOST="${GITLAB_STANDBY_HOST:-almalt}"
GITLAB_PRIMARY_SSH="${GITLAB_PRIMARY_SSH:-192.168.86.80}"
GITLAB_PRIMARY_PROJECT_ROOT="${GITLAB_PRIMARY_PROJECT_ROOT:-${PROJECT_ROOT}}"
GITLAB_LAN_DEVICE="${GITLAB_LAN_DEVICE:-}"
GITLAB_LAN_CONNECTION="${GITLAB_LAN_CONNECTION:-}"
K3D_CLUSTER_NAME="${K3D_CLUSTER_NAME:-gitlab-dev}"

usage() {
  cat <<'EOF'
Usage: bash scripts/switch_gitlab_role.sh [standby] [--yes]
       bash scripts/switch_gitlab_role.sh promote [--yes]

With no arguments (or `standby`), this host stops GitLab and releases the
shared endpoint, making it standby. Run `promote` on the standby host to SSH
to the primary, fence it, claim the endpoint locally, and start GitLab.

Defaults: primary almalinxo (192.168.86.80); standby almalt (192.168.86.141).
Required: passwordless sudo for nmcli/ip on both hosts and key-based SSH from
the standby to GITLAB_PRIMARY_SSH. Both hosts need this repository and a
matching .gitlab.env containing the shared GITLAB_EXTERNAL_IP.
EOF
}

local_host_role() {
  local hostname_short
  hostname_short="$(hostname -s)"
  case "${hostname_short}" in
    "${GITLAB_PRIMARY_HOST}") echo primary; return ;;
    "${GITLAB_STANDBY_HOST}") echo standby; return ;;
  esac

  if ip -o -4 address show | awk '{print $4}' | cut -d/ -f1 | grep -Fqx '192.168.86.80'; then
    echo primary
  elif ip -o -4 address show | awk '{print $4}' | cut -d/ -f1 | grep -Fqx '192.168.86.141'; then
    echo standby
  else
    echo "ERROR: Cannot identify this host as '${GITLAB_PRIMARY_HOST}' or '${GITLAB_STANDBY_HOST}'. Set the hostname or role variables." >&2
    exit 1
  fi
}

persist_role_settings() {
  local setting
  mkdir -p "$(dirname "${GITLAB_ENV_FILE}")"
  touch "${GITLAB_ENV_FILE}"
  for setting in GITLAB_PRIMARY_HOST GITLAB_STANDBY_HOST GITLAB_PRIMARY_SSH; do
    sed -i "/^${setting}=/d" "${GITLAB_ENV_FILE}"
  done
  {
    echo
    echo '# Primary/standby handoff settings (managed by switch_gitlab_role.sh).'
    echo "GITLAB_PRIMARY_HOST=${GITLAB_PRIMARY_HOST}"
    echo "GITLAB_STANDBY_HOST=${GITLAB_STANDBY_HOST}"
    echo "GITLAB_PRIMARY_SSH=${GITLAB_PRIMARY_SSH}"
  } >> "${GITLAB_ENV_FILE}"
}

require_tool() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "ERROR: $1 is required but not installed." >&2
    exit 1
  }
}

confirm() {
  [[ "${ASSUME_YES}" == true ]] && return
  local requested_action="$1"
  read -r -p "Type '${requested_action}' to continue: " answer
  [[ "${answer}" == "${requested_action}" ]] || { echo "No changes made."; exit 0; }
}

find_network_settings() {
  require_tool ip
  require_tool nmcli
  if [[ -z "${GITLAB_LAN_DEVICE}" ]]; then
    GITLAB_LAN_DEVICE="$(ip route show default | awk 'NR == 1 {print $5}')"
  fi
  [[ -n "${GITLAB_LAN_DEVICE}" ]] || { echo "ERROR: Could not determine GITLAB_LAN_DEVICE." >&2; exit 1; }
  if [[ -z "${GITLAB_LAN_CONNECTION}" ]]; then
    GITLAB_LAN_CONNECTION="$(nmcli -g GENERAL.CONNECTION device show "${GITLAB_LAN_DEVICE}")"
  fi
  [[ -n "${GITLAB_LAN_CONNECTION}" && "${GITLAB_LAN_CONNECTION}" != -- ]] || {
    echo "ERROR: Could not determine the active NetworkManager connection." >&2; exit 1;
  }
}

make_standby() {
  local role
  role="$(local_host_role)"
  find_network_settings
  confirm standby
  echo "Making ${role} host $(hostname -s) standby; stopping GitLab cluster '${K3D_CLUSTER_NAME}'..."
  if k3d cluster get "${K3D_CLUSTER_NAME}" >/dev/null 2>&1; then
    k3d cluster stop "${K3D_CLUSTER_NAME}"
  else
    echo "Cluster '${K3D_CLUSTER_NAME}' is already absent or stopped."
  fi
  echo "Removing shared endpoint ${GITLAB_EXTERNAL_IP}/${GITLAB_LAN_PREFIX} from ${GITLAB_LAN_CONNECTION}..."
  sudo nmcli connection modify "${GITLAB_LAN_CONNECTION}" -ipv4.addresses "${GITLAB_EXTERNAL_IP}/${GITLAB_LAN_PREFIX}" || true
  sudo nmcli device reapply "${GITLAB_LAN_DEVICE}" || true
  if ip -o -4 address show dev "${GITLAB_LAN_DEVICE}" | awk '{print $4}' | cut -d/ -f1 | grep -Fqx "${GITLAB_EXTERNAL_IP}"; then
    sudo ip address del "${GITLAB_EXTERNAL_IP}/${GITLAB_LAN_PREFIX}" dev "${GITLAB_LAN_DEVICE}"
  fi
  if ip -o -4 address show | awk '{print $4}' | cut -d/ -f1 | grep -Fqx "${GITLAB_EXTERNAL_IP}"; then
    echo "ERROR: ${GITLAB_EXTERNAL_IP} remains assigned on the primary; refusing handoff." >&2
    exit 1
  fi
  echo "Host is standby: GitLab stopped and ${GITLAB_EXTERNAL_IP} released."
}

promote() {
  [[ "$(local_host_role)" == standby ]] || {
    echo "ERROR: promote must run on standby '${GITLAB_STANDBY_HOST}'." >&2
    exit 1
  }
  require_tool ssh
  require_tool ip
  if ip -o -4 address show | awk '{print $4}' | cut -d/ -f1 | grep -Fqx "${GITLAB_EXTERNAL_IP}"; then
    echo "ERROR: ${GITLAB_EXTERNAL_IP} is already assigned locally; refusing a potentially split-brain promotion." >&2
    exit 1
  fi
  confirm promote
  echo "Fencing primary ${GITLAB_PRIMARY_HOST} through ${GITLAB_PRIMARY_SSH}..."
  ssh -o BatchMode=yes -o ConnectTimeout=10 "${GITLAB_PRIMARY_SSH}" \
    "GITLAB_EXTERNAL_IP='${GITLAB_EXTERNAL_IP}' GITLAB_LAN_PREFIX='${GITLAB_LAN_PREFIX}' GITLAB_PRIMARY_HOST='${GITLAB_PRIMARY_HOST}' GITLAB_STANDBY_HOST='${GITLAB_STANDBY_HOST}' K3D_CLUSTER_NAME='${K3D_CLUSTER_NAME}' bash '${GITLAB_PRIMARY_PROJECT_ROOT}/scripts/switch_gitlab_role.sh' standby --yes"
  echo "Claiming ${GITLAB_EXTERNAL_IP} on standby ${GITLAB_STANDBY_HOST}..."
  GITLAB_LAN_DEVICE="${GITLAB_LAN_DEVICE}" GITLAB_LAN_CONNECTION="${GITLAB_LAN_CONNECTION}" GITLAB_LAN_PREFIX="${GITLAB_LAN_PREFIX}" GITLAB_EXTERNAL_IP="${GITLAB_EXTERNAL_IP}" bash "${SCRIPT_DIR}/configure_gitlab_lan_ip.sh"
  echo "Starting GitLab on standby ${GITLAB_STANDBY_HOST}..."
  bash "${SCRIPT_DIR}/start_gitlab.sh"
  echo "Promotion complete: ${GITLAB_STANDBY_HOST} is active; ${GITLAB_PRIMARY_HOST} is standby."
}

ACTION="${1:-standby}"
ASSUME_YES=false
[[ "${2:-}" == --yes ]] && ASSUME_YES=true
case "${ACTION}" in
  promote) persist_role_settings; promote ;;
  standby) persist_role_settings; make_standby ;;
  -h|--help) usage ;;
  *) usage >&2; exit 2 ;;
esac
