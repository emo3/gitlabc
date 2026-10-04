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
GITLAB_STANDBY_SSH="${GITLAB_STANDBY_SSH:-192.168.86.141}"
GITLAB_PEER_PROJECT_ROOT="${GITLAB_PEER_PROJECT_ROOT:-${PROJECT_ROOT}}"
GITLAB_ENSURE_PEER_ACTIVE="${GITLAB_ENSURE_PEER_ACTIVE:-true}"
GITLAB_LAN_DEVICE="${GITLAB_LAN_DEVICE:-}"
GITLAB_LAN_CONNECTION="${GITLAB_LAN_CONNECTION:-}"
K3D_CLUSTER_NAME="${K3D_CLUSTER_NAME:-gitlab-dev}"

usage() {
  cat <<'EOF'
Usage: bash scripts/switch_gitlab_role.sh [promote|standby]

With no arguments, reconcile the configured default roles: the primary host
is active and the standby host is inactive. Run `promote` on either host to
fence the other host, claim the endpoint locally, and start GitLab there.
Run `standby` to explicitly stop GitLab and release the shared endpoint on
this host.

Defaults: primary almalinxo (192.168.86.80); standby almalt (192.168.86.141).
Required: passwordless sudo for nmcli/ip on both hosts and key-based SSH in
both directions. Both hosts need this repository and a matching .gitlab.env
containing the shared GITLAB_EXTERNAL_IP.
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
  for setting in GITLAB_PRIMARY_HOST GITLAB_STANDBY_HOST GITLAB_PRIMARY_SSH GITLAB_STANDBY_SSH; do
    sed -i "/^${setting}=/d" "${GITLAB_ENV_FILE}"
  done
  {
    echo
    echo '# Primary/standby handoff settings (managed by switch_gitlab_role.sh).'
    echo "GITLAB_PRIMARY_HOST=${GITLAB_PRIMARY_HOST}"
    echo "GITLAB_STANDBY_HOST=${GITLAB_STANDBY_HOST}"
    echo "GITLAB_PRIMARY_SSH=${GITLAB_PRIMARY_SSH}"
    echo "GITLAB_STANDBY_SSH=${GITLAB_STANDBY_SSH}"
  } >> "${GITLAB_ENV_FILE}"
}

require_tool() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "ERROR: $1 is required but not installed." >&2
    exit 1
  }
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

local_host_is_active() {
  ip -o -4 address show | awk '{print $4}' | cut -d/ -f1 | grep -Fqx "${GITLAB_EXTERNAL_IP}" \
    && k3d cluster get "${K3D_CLUSTER_NAME}" >/dev/null 2>&1
}

peer_host_is_active() {
  local peer_ssh="$1"
  ssh -o BatchMode=yes -o ConnectTimeout=10 "${peer_ssh}" \
    "ip -o -4 address show | awk '{print \$4}' | cut -d/ -f1 | grep -Fqx '${GITLAB_EXTERNAL_IP}' && k3d cluster get '${K3D_CLUSTER_NAME}' >/dev/null 2>&1"
}

peer_details() {
  local local_role
  local_role="$(local_host_role)"
  if [[ "${local_role}" == primary ]]; then
    PEER_HOST="${GITLAB_STANDBY_HOST}"
    PEER_SSH="${GITLAB_STANDBY_SSH}"
  else
    PEER_HOST="${GITLAB_PRIMARY_HOST}"
    PEER_SSH="${GITLAB_PRIMARY_SSH}"
  fi
}

make_standby() {
  local role peer_host peer_ssh
  role="$(local_host_role)"
  peer_details
  peer_host="${PEER_HOST}"
  peer_ssh="${PEER_SSH}"
  require_tool ssh
  require_tool ip
  if ! local_host_is_active && peer_host_is_active "${peer_ssh}"; then
    echo "Already standby: ${peer_host} is active and $(hostname -s) is inactive."
    return
  fi
  find_network_settings
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
  if [[ "${GITLAB_ENSURE_PEER_ACTIVE}" != true ]]; then
    return
  fi
  echo "Ensuring peer ${peer_host} is active..."
  ssh -o BatchMode=yes -o ConnectTimeout=10 "${peer_ssh}" \
    "GITLAB_EXTERNAL_IP='${GITLAB_EXTERNAL_IP}' GITLAB_LAN_PREFIX='${GITLAB_LAN_PREFIX}' GITLAB_PRIMARY_HOST='${GITLAB_PRIMARY_HOST}' GITLAB_STANDBY_HOST='${GITLAB_STANDBY_HOST}' GITLAB_PRIMARY_SSH='${GITLAB_PRIMARY_SSH}' GITLAB_STANDBY_SSH='${GITLAB_STANDBY_SSH}' K3D_CLUSTER_NAME='${K3D_CLUSTER_NAME}' bash '${GITLAB_PEER_PROJECT_ROOT}/scripts/switch_gitlab_role.sh' promote"
}

promote() {
  local peer_host peer_ssh
  peer_details
  peer_host="${PEER_HOST}"
  peer_ssh="${PEER_SSH}"
  require_tool ssh
  require_tool ip
  if local_host_is_active && ! peer_host_is_active "${peer_ssh}"; then
    echo "Already active: $(hostname -s) is active and ${peer_host} is standby."
    return
  fi
  if ip -o -4 address show | awk '{print $4}' | cut -d/ -f1 | grep -Fqx "${GITLAB_EXTERNAL_IP}"; then
    echo "ERROR: ${GITLAB_EXTERNAL_IP} is already assigned locally; refusing a potentially split-brain promotion." >&2
    exit 1
  fi
  echo "Fencing peer ${peer_host} through ${peer_ssh}..."
  ssh -o BatchMode=yes -o ConnectTimeout=10 "${peer_ssh}" \
    "GITLAB_EXTERNAL_IP='${GITLAB_EXTERNAL_IP}' GITLAB_LAN_PREFIX='${GITLAB_LAN_PREFIX}' GITLAB_PRIMARY_HOST='${GITLAB_PRIMARY_HOST}' GITLAB_STANDBY_HOST='${GITLAB_STANDBY_HOST}' GITLAB_PRIMARY_SSH='${GITLAB_PRIMARY_SSH}' GITLAB_STANDBY_SSH='${GITLAB_STANDBY_SSH}' K3D_CLUSTER_NAME='${K3D_CLUSTER_NAME}' GITLAB_ENSURE_PEER_ACTIVE=false bash '${GITLAB_PEER_PROJECT_ROOT}/scripts/switch_gitlab_role.sh' standby"
  echo "Claiming ${GITLAB_EXTERNAL_IP} on $(hostname -s)..."
  GITLAB_LAN_DEVICE="${GITLAB_LAN_DEVICE}" GITLAB_LAN_CONNECTION="${GITLAB_LAN_CONNECTION}" GITLAB_LAN_PREFIX="${GITLAB_LAN_PREFIX}" GITLAB_EXTERNAL_IP="${GITLAB_EXTERNAL_IP}" bash "${SCRIPT_DIR}/configure_gitlab_lan_ip.sh"
  echo "Starting GitLab on $(hostname -s)..."
  bash "${SCRIPT_DIR}/start_gitlab.sh"
  echo "Promotion complete: $(hostname -s) is active; ${peer_host} is standby."
}

ACTION="${1:-default}"
case "${ACTION}" in
  default)
    persist_role_settings
    # The configured primary is the default active host. Invoking the helper
    # on the standby preserves that policy by ensuring its primary peer is up.
    if [[ "$(local_host_role)" == primary ]]; then
      promote
    else
      make_standby
    fi
    ;;
  promote) persist_role_settings; promote ;;
  standby) persist_role_settings; make_standby ;;
  -h|--help) usage ;;
  *) usage >&2; exit 2 ;;
esac
