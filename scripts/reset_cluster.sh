#!/bin/bash

# Reset the local GitLab install and delete the k3d cluster.

set -eo pipefail
[[ "${TRACE}" ]] && set -x

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

K3D_CLUSTER_NAME="${K3D_CLUSTER_NAME:-gitlab-dev}"

cd "${PROJECT_ROOT}"

bash scripts/reset_local.sh

echo "Deleting k3d cluster '${K3D_CLUSTER_NAME}'..."
k3d cluster delete "${K3D_CLUSTER_NAME}"

echo "Full reset complete."
echo "Run the Ansible playbook to recreate the cluster:"
echo "ansible-playbook -i localhost, --connection=local --ask-become-pass ansible-install-k8s-tools-gitlab-deps.yml"
