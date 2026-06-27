#!/bin/bash

# Deploy a stable GitLab chart release from the official Helm repository.

set -eo pipefail
[[ "${TRACE}" ]] && set -x

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

NAMESPACE="${NAMESPACE:-gitlab}"
RELEASE_NAME="${RELEASE_NAME:-gitlab}"
GITLAB_DOMAIN="${GITLAB_DOMAIN:-127.0.0.1.nip.io}"
GITLAB_EXTERNAL_IP="${GITLAB_EXTERNAL_IP:-127.0.0.1}"
GITLAB_HTTPS="${GITLAB_HTTPS:-false}"
GITLAB_TLS_SECRET="${GITLAB_TLS_SECRET:-}"
CERTMANAGER_EMAIL="${CERTMANAGER_EMAIL:-infuse.1301@gmail.com}"
VALUES_FILE="${VALUES_FILE:-${PROJECT_ROOT}/.values/dev-external.values.yaml}"
GITLAB_HELM_REPO_NAME="${GITLAB_HELM_REPO_NAME:-gitlab}"
GITLAB_HELM_REPO_URL="${GITLAB_HELM_REPO_URL:-https://charts.gitlab.io/}"
GITLAB_CHART_REF="${GITLAB_CHART_REF:-${GITLAB_HELM_REPO_NAME}/gitlab}"
GITLAB_CHART_VERSION="${GITLAB_CHART_VERSION:-10.1.1}"
K3D_CLUSTER_NAME="${K3D_CLUSTER_NAME:-gitlab-dev}"
KUBE_CONTEXT="${KUBE_CONTEXT:-k3d-${K3D_CLUSTER_NAME}}"

cd "${PROJECT_ROOT}"

if [[ ! -f "${VALUES_FILE}" ]]; then
  echo "ERROR: Values file not found at ${VALUES_FILE}."
  echo "Run: bash scripts/dev_dependencies.sh setup"
  exit 1
fi

if ! kubectl config get-contexts "${KUBE_CONTEXT}" > /dev/null 2>&1; then
  echo "ERROR: Kubernetes context '${KUBE_CONTEXT}' was not found."
  echo "Run the Ansible playbook first, or set KUBE_CONTEXT to the context you want to deploy to."
  exit 1
fi

if ! helm repo list | awk '{print $1}' | grep -qx "${GITLAB_HELM_REPO_NAME}"; then
  echo "Adding Helm repo '${GITLAB_HELM_REPO_NAME}'..."
  helm repo add "${GITLAB_HELM_REPO_NAME}" "${GITLAB_HELM_REPO_URL}"
fi

echo "Updating Helm repo '${GITLAB_HELM_REPO_NAME}'..."
helm repo update "${GITLAB_HELM_REPO_NAME}"

case "${GITLAB_HTTPS}" in
  true)
    GITLAB_SCHEME="https"
    TLS_ENABLED="true"
    ;;
  false)
    GITLAB_SCHEME="http"
    TLS_ENABLED="false"
    ;;
  *)
    echo "ERROR: GITLAB_HTTPS must be 'true' or 'false'."
    exit 1
    ;;
esac

TLS_SECRET_ARGS=()
if [[ -n "${GITLAB_TLS_SECRET}" ]]; then
  if [[ "${GITLAB_HTTPS}" != "true" ]]; then
    echo "ERROR: GITLAB_TLS_SECRET requires GITLAB_HTTPS=true."
    exit 1
  fi
  if ! kubectl --context "${KUBE_CONTEXT}" -n "${NAMESPACE}" get secret "${GITLAB_TLS_SECRET}" > /dev/null 2>&1; then
    echo "ERROR: TLS secret '${GITLAB_TLS_SECRET}' was not found in namespace '${NAMESPACE}'."
    echo "Run: bash scripts/create_mkcert.sh"
    exit 1
  fi
  TLS_SECRET_ARGS+=(--set "global.ingress.tls.secretName=${GITLAB_TLS_SECRET}")
fi

echo "Deploying GitLab release '${RELEASE_NAME}' to namespace '${NAMESPACE}'..."
helm upgrade --install "${RELEASE_NAME}" "${GITLAB_CHART_REF}" \
  --kube-context "${KUBE_CONTEXT}" \
  --namespace "${NAMESPACE}" \
  --version "${GITLAB_CHART_VERSION}" \
  --timeout 600s \
  -f "${VALUES_FILE}" \
  --set global.hosts.domain="${GITLAB_DOMAIN}" \
  --set global.hosts.externalIP="${GITLAB_EXTERNAL_IP}" \
  --set certmanager-issuer.email="${CERTMANAGER_EMAIL}" \
  --set global.hosts.https="${GITLAB_HTTPS}" \
  --set global.ingress.enabled=true \
  --set global.ingress.configureCertmanager=false \
  --set global.ingress.tls.enabled="${TLS_ENABLED}" \
  "${TLS_SECRET_ARGS[@]}" \
  --set nginx-ingress.enabled=true \
  --set global.gatewayApi.enabled=false \
  --set gatewayApiResources.enabled=false \
  --set gitlab-runner.install=false \
  --set prometheus.install=false

echo "GitLab deploy submitted."
echo "Open: ${GITLAB_SCHEME}://gitlab.${GITLAB_DOMAIN}/users/sign_in"
if [[ "${GITLAB_HTTPS}" == "true" ]]; then
  if [[ -n "${GITLAB_TLS_SECRET}" ]]; then
    echo "TLS uses Kubernetes secret '${GITLAB_TLS_SECRET}'."
  else
    echo "TLS uses the chart-generated self-signed certificate unless you provide your own TLS secret."
  fi
fi
