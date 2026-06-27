#!/bin/bash

# Reset the local GitLab install while keeping the k3d cluster.

set -eo pipefail
[[ "${TRACE}" ]] && set -x

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

NAMESPACE="${NAMESPACE:-gitlab}"
RELEASE_NAME="${RELEASE_NAME:-gitlab}"
DELETE_LOCAL_CACHE="${DELETE_LOCAL_CACHE:-true}"
K3D_CLUSTER_NAME="${K3D_CLUSTER_NAME:-gitlab-dev}"
KUBE_CONTEXT="${KUBE_CONTEXT:-k3d-${K3D_CLUSTER_NAME}}"

cd "${PROJECT_ROOT}"

case "${DELETE_LOCAL_CACHE}" in
  true|false)
    ;;
  *)
    echo "ERROR: DELETE_LOCAL_CACHE must be 'true' or 'false'."
    exit 1
    ;;
esac

echo "Resetting GitLab release and external dependencies in namespace '${NAMESPACE}'..."

if ! kubectl config get-contexts "${KUBE_CONTEXT}" > /dev/null 2>&1; then
  echo "ERROR: Kubernetes context '${KUBE_CONTEXT}' was not found."
  echo "Run the Ansible playbook first, or set KUBE_CONTEXT to the context you want to reset."
  exit 1
fi

kubectl config use-context "${KUBE_CONTEXT}" > /dev/null

helm uninstall "${RELEASE_NAME}" -n "${NAMESPACE}" --kube-context "${KUBE_CONTEXT}" --ignore-not-found
if kubectl --context "${KUBE_CONTEXT}" get namespace "${NAMESPACE}" > /dev/null 2>&1; then
  KUBE_CONTEXT="${KUBE_CONTEXT}" bash scripts/dev_dependencies.sh teardown
  kubectl --context "${KUBE_CONTEXT}" delete namespace "${NAMESPACE}" --ignore-not-found --wait=false
else
  echo "Namespace '${NAMESPACE}' was not found. Skipping in-cluster dependency teardown."
fi

if [[ "${DELETE_LOCAL_CACHE}" == "true" ]]; then
  rm -rf .values .chart
  echo "Removed local generated files: .values .chart"
fi

echo "Reset complete. The k3d cluster was kept."
echo "Run: bash scripts/dev_dependencies.sh setup"
echo "Then: bash scripts/deploy_gitlab.sh"
