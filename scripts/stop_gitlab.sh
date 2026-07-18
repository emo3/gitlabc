#!/bin/bash

# Stop the local GitLab k3d cluster without removing GitLab data.

set -euo pipefail
[[ -n "${TRACE:-}" ]] && set -x

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

K3D_CLUSTER_NAME="${K3D_CLUSTER_NAME:-gitlab-dev}"

if ! command -v k3d > /dev/null 2>&1; then
  echo "ERROR: k3d is required to stop cluster '${K3D_CLUSTER_NAME}'."
  exit 1
fi

cd "${PROJECT_ROOT}"

if ! k3d cluster get "${K3D_CLUSTER_NAME}" > /dev/null 2>&1; then
  echo "ERROR: k3d cluster '${K3D_CLUSTER_NAME}' was not found."
  exit 1
fi

echo "Stopping k3d cluster '${K3D_CLUSTER_NAME}'..."
k3d cluster stop "${K3D_CLUSTER_NAME}"
echo "GitLab stopped. Helm releases, Kubernetes PVCs, and Docker volumes were retained."
