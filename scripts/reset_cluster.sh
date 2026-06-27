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

if kubectl config get-contexts "${KUBE_CONTEXT}" > /dev/null 2>&1; then
  bash scripts/reset_local.sh
else
  echo "Kubernetes context '${KUBE_CONTEXT}' was not found. Skipping in-cluster reset."
  rm -rf .values .chart
  echo "Removed local generated files: .values .chart"
fi

echo "Deleting k3d cluster '${K3D_CLUSTER_NAME}'..."
k3d cluster delete "${K3D_CLUSTER_NAME}"

if [[ "${PRUNE_DOCKER}" == "true" ]]; then
  echo "Pruning unused Docker containers, images, networks, volumes, and build cache..."
  docker system prune -a --volumes -f
  docker volume prune -a -f
  docker buildx history rm --all || true
  docker system df
fi

echo "Full reset complete."
echo "Run the Ansible playbook to recreate the cluster:"
echo "ansible-playbook -i localhost, --connection=local --ask-become-pass ansible-install-k8s-tools-gitlab-deps.yml"
