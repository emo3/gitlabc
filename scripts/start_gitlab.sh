#!/bin/bash

# Reconcile and start the local GitLab environment without removing its data.

set -euo pipefail
[[ -n "${TRACE:-}" ]] && set -x

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

K3D_CLUSTER_NAME="${K3D_CLUSTER_NAME:-gitlab-dev}"
BOOTSTRAP="${BOOTSTRAP:-false}"
GITLAB_ENV_FILE="${GITLAB_ENV_FILE:-${PROJECT_ROOT}/.gitlab.env}"
if [[ -f "${GITLAB_ENV_FILE}" ]]; then
  # shellcheck disable=SC1090
  source "${GITLAB_ENV_FILE}"
fi
GITLAB_DOMAIN="${GITLAB_DOMAIN:-127.0.0.1.nip.io}"

cd "${PROJECT_ROOT}"

case "${BOOTSTRAP}" in
  true)
    if ! command -v ansible-playbook > /dev/null 2>&1; then
      echo "ERROR: ansible-playbook is required when BOOTSTRAP=true."
      exit 1
    fi

    echo "Reconciling privileged prerequisites and k3d cluster '${K3D_CLUSTER_NAME}'..."
    ansible-playbook -i localhost, --connection=local \
      -e "k3d_cluster_name=${K3D_CLUSTER_NAME}" \
      -e "gitlab_domain=${GITLAB_DOMAIN}" \
      ansible-install-k8s-tools-gitlab-deps.yml
    ;;
  false)
    if ! command -v k3d > /dev/null 2>&1; then
      echo "ERROR: k3d is required. Run BOOTSTRAP=true bash scripts/start_gitlab.sh for first-time setup."
      exit 1
    fi

    if ! k3d cluster get "${K3D_CLUSTER_NAME}" > /dev/null 2>&1; then
      echo "ERROR: k3d cluster '${K3D_CLUSTER_NAME}' was not found."
      echo "Run BOOTSTRAP=true bash scripts/start_gitlab.sh for first-time setup."
      exit 1
    fi

    server_container="k3d-${K3D_CLUSTER_NAME}-server-0"
    if [[ "$(docker inspect -f '{{.State.Running}}' "${server_container}" 2>/dev/null || true)" != "true" ]]; then
      echo "Starting k3d cluster '${K3D_CLUSTER_NAME}'..."
      k3d cluster start "${K3D_CLUSTER_NAME}"
    else
      echo "k3d cluster '${K3D_CLUSTER_NAME}' is already running."
    fi
    ;;
  *)
    echo "ERROR: BOOTSTRAP must be 'true' or 'false'."
    exit 1
    ;;
esac

echo "Reconciling GitLab deployment..."
K3D_CLUSTER_NAME="${K3D_CLUSTER_NAME}" bash "${SCRIPT_DIR}/deploy_gitlab.sh"

echo "Waiting for GitLab to become healthy..."
K3D_CLUSTER_NAME="${K3D_CLUSTER_NAME}" bash "${SCRIPT_DIR}/check_status.sh"
