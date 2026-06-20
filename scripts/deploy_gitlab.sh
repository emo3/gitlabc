#!/bin/bash

# Deploy the GitLab chart from an ignored local chart mirror.

set -eo pipefail
[[ "${TRACE}" ]] && set -x

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

GITLAB_CHART_ROOT="${GITLAB_CHART_ROOT:-${PROJECT_ROOT}/../gitlab}"
LOCAL_CHART_ROOT="${LOCAL_CHART_ROOT:-${PROJECT_ROOT}/.chart/gitlab}"
NAMESPACE="${NAMESPACE:-gitlab}"
RELEASE_NAME="${RELEASE_NAME:-gitlab}"
GITLAB_DOMAIN="${GITLAB_DOMAIN:-127.0.0.1.nip.io}"
GITLAB_EXTERNAL_IP="${GITLAB_EXTERNAL_IP:-127.0.0.1}"
CERTMANAGER_EMAIL="${CERTMANAGER_EMAIL:-infuse.1301@gmail.com}"
VALUES_FILE="${VALUES_FILE:-${PROJECT_ROOT}/.values/dev-external.values.yaml}"

cd "${PROJECT_ROOT}"

if [[ ! -f "${GITLAB_CHART_ROOT}/Chart.yaml" ]]; then
  echo "ERROR: GitLab chart checkout not found at ${GITLAB_CHART_ROOT}."
  echo "Set GITLAB_CHART_ROOT or clone the chart to ../gitlab."
  exit 1
fi

if [[ ! -f "${VALUES_FILE}" ]]; then
  echo "ERROR: Values file not found at ${VALUES_FILE}."
  echo "Run: bash scripts/dev_dependencies.sh setup"
  exit 1
fi

echo "Refreshing local chart mirror at ${LOCAL_CHART_ROOT}..."
mkdir -p "$(dirname "${LOCAL_CHART_ROOT}")"
rsync -a --delete --exclude .git "${GITLAB_CHART_ROOT}/" "${LOCAL_CHART_ROOT}/"
chmod -R u+w "${LOCAL_CHART_ROOT}"

echo "Updating Helm dependencies in local chart mirror..."
helm dependency update "${LOCAL_CHART_ROOT}"

echo "Deploying GitLab release '${RELEASE_NAME}' to namespace '${NAMESPACE}'..."
helm upgrade --install "${RELEASE_NAME}" "${LOCAL_CHART_ROOT}" \
  --namespace "${NAMESPACE}" \
  --timeout 600s \
  -f "${VALUES_FILE}" \
  --set global.hosts.domain="${GITLAB_DOMAIN}" \
  --set global.hosts.externalIP="${GITLAB_EXTERNAL_IP}" \
  --set certmanager-issuer.email="${CERTMANAGER_EMAIL}" \
  --set global.hosts.https=false \
  --set global.ingress.enabled=true \
  --set global.ingress.configureCertmanager=false \
  --set global.ingress.tls.enabled=false \
  --set nginx-ingress.enabled=true \
  --set global.gatewayApi.enabled=false \
  --set gatewayApiResources.enabled=false \
  --set gitlab-runner.install=false \
  --set prometheus.install=false

echo "GitLab deploy submitted."
echo "Open: http://gitlab.${GITLAB_DOMAIN}/users/sign_in"
