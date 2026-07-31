#!/bin/bash

# Reconcile and start the local GitLab environment without removing its data.

set -euo pipefail
[[ -n "${TRACE:-}" ]] && set -x

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

K3D_CLUSTER_NAME="${K3D_CLUSTER_NAME:-gitlab-dev}"
GITLAB_ENV_FILE="${GITLAB_ENV_FILE:-${PROJECT_ROOT}/.gitlab.env}"
if [[ -f "${GITLAB_ENV_FILE}" ]]; then
  # shellcheck disable=SC1090
  source "${GITLAB_ENV_FILE}"
fi
GITLAB_DOMAIN="${GITLAB_DOMAIN:-192.168.86.50.nip.io}"
GITLAB_EXTERNAL_IP="${GITLAB_EXTERNAL_IP:-192.168.86.50}"
GITLAB_SSH_HOST="${GITLAB_SSH_HOST:-gitlab.${GITLAB_DOMAIN}}"
GITLAB_DEPLOY_PROFILE="${GITLAB_DEPLOY_PROFILE:-local-mkcert}"

cd "${PROJECT_ROOT}"

function local_address_is_assigned() {
  if command -v ip > /dev/null 2>&1; then
    ip -o -4 address show | awk '{print $4}' | cut -d/ -f1 |
      grep -Fqx "${GITLAB_EXTERNAL_IP}"
    return
  fi

  if command -v ifconfig > /dev/null 2>&1; then
    ifconfig | awk '$1 == "inet" {print $2}' | grep -Fqx "${GITLAB_EXTERNAL_IP}"
    return
  fi

  echo "WARNING: Could not verify whether ${GITLAB_EXTERNAL_IP} is assigned; neither ip nor ifconfig is installed."
  return 0
}

case "${GITLAB_DEPLOY_PROFILE}" in
  local|local-mkcert)
    if [[ "${GITLAB_EXTERNAL_IP}" != "127.0.0.1" ]] && ! local_address_is_assigned; then
      echo "ERROR: GITLAB_EXTERNAL_IP '${GITLAB_EXTERNAL_IP}' is not assigned to this host."
      echo "Configure the stable LAN endpoint before starting GitLab:"
      echo "  ${PROJECT_ROOT}/README-mk.md#configure-the-address"
      exit 1
    fi
    ;;
esac

if ! command -v ansible-playbook > /dev/null 2>&1; then
  echo "ERROR: ansible-playbook is required to reconcile the local GitLab environment."
  exit 1
fi

echo "Reconciling privileged prerequisites and k3d cluster '${K3D_CLUSTER_NAME}'..."
ansible-playbook -i localhost, --connection=local \
  -e "k3d_cluster_name=${K3D_CLUSTER_NAME}" \
  -e "gitlab_domain=${GITLAB_DOMAIN}" \
  ansible-install-k8s-tools-gitlab-deps.yml

echo "Reconciling GitLab deployment..."
K3D_CLUSTER_NAME="${K3D_CLUSTER_NAME}" \
  GITLAB_DOMAIN="${GITLAB_DOMAIN}" \
  GITLAB_EXTERNAL_IP="${GITLAB_EXTERNAL_IP}" \
  GITLAB_SSH_HOST="${GITLAB_SSH_HOST}" \
  GITLAB_DEPLOY_PROFILE="${GITLAB_DEPLOY_PROFILE}" \
  bash "${SCRIPT_DIR}/deploy_gitlab.sh"

echo "Waiting for GitLab to become healthy..."
K3D_CLUSTER_NAME="${K3D_CLUSTER_NAME}" bash "${SCRIPT_DIR}/check_status.sh"
