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

cd "${PROJECT_ROOT}"

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
K3D_CLUSTER_NAME="${K3D_CLUSTER_NAME}" bash "${SCRIPT_DIR}/deploy_gitlab.sh"

echo "Waiting for GitLab to become healthy..."
K3D_CLUSTER_NAME="${K3D_CLUSTER_NAME}" bash "${SCRIPT_DIR}/check_status.sh"
