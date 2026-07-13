#!/bin/bash

# Generate a locally trusted mkcert wildcard certificate and apply it as a
# Kubernetes TLS secret for the GitLab chart ingress.

set -eo pipefail
[[ "${TRACE}" ]] && set -x

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Keep direct certificate regeneration aligned with the machine-local GitLab
# endpoint configuration used by deployment and k3d registry setup.
GITLAB_ENV_FILE="${GITLAB_ENV_FILE:-${PROJECT_ROOT}/.gitlab.env}"
if [[ -f "${GITLAB_ENV_FILE}" ]]; then
  # shellcheck disable=SC1090
  source "${GITLAB_ENV_FILE}"
fi

NAMESPACE="${NAMESPACE:-gitlab}"
GITLAB_DOMAIN="${GITLAB_DOMAIN:-127.0.0.1.nip.io}"
GITLAB_HOST="${GITLAB_HOST:-gitlab.${GITLAB_DOMAIN}}"
GITLAB_TLS_SECRET="${GITLAB_TLS_SECRET:-gitlab-local-tls}"
CERT_DIR="${CERT_DIR:-${PROJECT_ROOT}/.certs}"
CERT_FILE="${CERT_FILE:-${CERT_DIR}/gitlab-local.pem}"
KEY_FILE="${KEY_FILE:-${CERT_DIR}/gitlab-local-key.pem}"
FORCE_REGENERATE_CERT="${FORCE_REGENERATE_CERT:-false}"
K3D_CLUSTER_NAME="${K3D_CLUSTER_NAME:-gitlab-dev}"
KUBE_CONTEXT="${KUBE_CONTEXT:-k3d-${K3D_CLUSTER_NAME}}"

KUBECTL=(kubectl --context "${KUBE_CONTEXT}")

if ! kubectl config get-contexts "${KUBE_CONTEXT}" > /dev/null 2>&1; then
  echo "ERROR: Kubernetes context '${KUBE_CONTEXT}' was not found."
  echo "Run the Ansible playbook first, or set KUBE_CONTEXT to the context you want to use."
  exit 1
fi

mkdir -p "${CERT_DIR}"

case "${FORCE_REGENERATE_CERT}" in
  true|false)
    ;;
  *)
    echo "ERROR: FORCE_REGENERATE_CERT must be 'true' or 'false'."
    exit 1
    ;;
esac

if [[ "${FORCE_REGENERATE_CERT}" == "false" && -f "${CERT_FILE}" && -f "${KEY_FILE}" ]]; then
  echo "Reusing existing certificate files:"
  echo "  cert: ${CERT_FILE}"
  echo "  key:  ${KEY_FILE}"
else
  if [[ "${FORCE_REGENERATE_CERT}" == "false" && ( -f "${CERT_FILE}" || -f "${KEY_FILE}" ) ]]; then
    echo "ERROR: Only one certificate file exists."
    echo "  cert: ${CERT_FILE}"
    echo "  key:  ${KEY_FILE}"
    echo "Remove the orphaned file or rerun with FORCE_REGENERATE_CERT=true."
    exit 1
  fi

  if ! command -v mkcert > /dev/null 2>&1; then
    echo "ERROR: mkcert was not found."
    echo "Install mkcert, then rerun this script."
    exit 1
  fi

  echo "Installing mkcert local CA if needed..."
  mkcert -install

  echo "Generating local GitLab certificate..."
  mkcert \
    -cert-file "${CERT_FILE}" \
    -key-file "${KEY_FILE}" \
    "${GITLAB_HOST}" \
    "*.${GITLAB_DOMAIN}" \
    "${GITLAB_DOMAIN}" \
    localhost \
    127.0.0.1
fi

echo "Ensuring namespace '${NAMESPACE}' exists..."
"${KUBECTL[@]}" create namespace "${NAMESPACE}" --dry-run=client -o yaml | "${KUBECTL[@]}" apply -f -

echo "Applying TLS secret '${GITLAB_TLS_SECRET}'..."
"${KUBECTL[@]}" -n "${NAMESPACE}" create secret tls "${GITLAB_TLS_SECRET}" \
  --cert="${CERT_FILE}" \
  --key="${KEY_FILE}" \
  --dry-run=client \
  -o yaml | "${KUBECTL[@]}" apply -f -

echo "Created/updated TLS secret '${GITLAB_TLS_SECRET}' in namespace '${NAMESPACE}'."
echo "Deploy with:"
echo "GITLAB_TLS_SECRET=${GITLAB_TLS_SECRET} bash scripts/deploy_gitlab.sh"
