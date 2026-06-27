#!/bin/bash

# Reset the local GitLab install and delete the k3d cluster.

set -eo pipefail
[[ "${TRACE}" ]] && set -x

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

K3D_CLUSTER_NAME="${K3D_CLUSTER_NAME:-gitlab-dev}"
KUBE_CONTEXT="${KUBE_CONTEXT:-k3d-${K3D_CLUSTER_NAME}}"
PRUNE_DOCKER="${PRUNE_DOCKER:-true}"

cd "${PROJECT_ROOT}"

case "${PRUNE_DOCKER}" in
  true|false)
    ;;
  *)
    echo "ERROR: PRUNE_DOCKER must be 'true' or 'false'."
    exit 1
    ;;
esac

if kubectl config get-contexts "${KUBE_CONTEXT}" > /dev/null 2>&1; then
  bash scripts/reset_local.sh
else
  echo "Kubernetes context '${KUBE_CONTEXT}' was not found. Skipping in-cluster reset."
  rm -rf .values .chart
  echo "Removed local generated files: .values .chart"
fi

if ! command -v k3d > /dev/null 2>&1; then
  echo "ERROR: k3d is required to delete cluster '${K3D_CLUSTER_NAME}'."
  exit 1
fi

if k3d cluster get "${K3D_CLUSTER_NAME}" > /dev/null 2>&1; then
  echo "Deleting k3d cluster '${K3D_CLUSTER_NAME}'..."
  k3d cluster delete "${K3D_CLUSTER_NAME}"
else
  echo "k3d cluster '${K3D_CLUSTER_NAME}' was not found. Skipping cluster delete."
fi

if [[ "${PRUNE_DOCKER}" == "true" ]]; then
  if ! command -v docker > /dev/null 2>&1; then
    echo "ERROR: docker is required when PRUNE_DOCKER=true."
    exit 1
  fi
  echo "Pruning unused Docker containers, images, networks, volumes, and build cache..."
  docker system prune -a --volumes -f
  docker volume prune -a -f
  docker buildx history rm --all || true
  docker system df
fi

echo "Full reset complete."
echo "Run the Ansible playbook to recreate the cluster:"
echo "ansible-playbook -i localhost, --connection=local --ask-become-pass ansible-install-k8s-tools-gitlab-deps.yml"
