#!/bin/bash

# Check the standalone GitLab Runner Helm release and optionally upgrade it.

set -eo pipefail
[[ "${TRACE}" ]] && set -x

GITLAB_HELM_REPO_NAME="${GITLAB_HELM_REPO_NAME:-gitlab}"
GITLAB_HELM_REPO_URL="${GITLAB_HELM_REPO_URL:-https://charts.gitlab.io/}"
GITLAB_RUNNER_CHART_REF="${GITLAB_RUNNER_CHART_REF:-${GITLAB_HELM_REPO_NAME}/gitlab-runner}"
RELEASE_NAME="${RELEASE_NAME:-gitlab-runner}"
NAMESPACE="${NAMESPACE:-gitlab}"
K3D_CLUSTER_NAME="${K3D_CLUSTER_NAME:-gitlab-dev}"
KUBE_CONTEXT="${KUBE_CONTEXT:-k3d-${K3D_CLUSTER_NAME}}"
HELM_TIMEOUT="${HELM_TIMEOUT:-10m}"

APPLY=false
ALLOW_MINOR=false
ALLOW_MAJOR=false

function usage() {
  cat <<'USAGE'
Usage: bash scripts/update_gitlab_runner_chart_version.sh [-a] [-m] [-M] [-n NAMESPACE] [-r RELEASE]

Checks the installed standalone GitLab Runner release against the latest
gitlab/gitlab-runner Helm chart.

Options:
  -a  Upgrade the installed runner release, retaining its existing Helm values.
  -m  Permit -a across minor chart versions, such as 0.90.x -> 0.91.x.
  -M  Permit -a across major chart versions.
  -n  Kubernetes namespace (default: gitlab).
  -r  Helm release name (default: gitlab-runner).
  -h  Show this help.

Environment:
  KUBE_CONTEXT              Kubernetes context (default: k3d-gitlab-dev).
  GITLAB_RUNNER_CHART_REF   Runner chart reference (default: gitlab/gitlab-runner).
  HELM_TIMEOUT              Upgrade timeout (default: 10m).
USAGE
}

function require_command() {
  local name="$1"

  if ! command -v "${name}" >/dev/null 2>&1; then
    echo "ERROR: ${name} is required but not installed."
    exit 1
  fi
}

while getopts ":amMn:r:h" opt; do
  case "${opt}" in
    a)
      APPLY=true
      ;;
    m)
      ALLOW_MINOR=true
      ;;
    M)
      ALLOW_MAJOR=true
      ;;
    n)
      NAMESPACE="${OPTARG}"
      ;;
    r)
      RELEASE_NAME="${OPTARG}"
      ;;
    h)
      usage
      exit 0
      ;;
    :)
      echo "ERROR: -${OPTARG} requires an argument."
      usage
      exit 1
      ;;
    \?)
      echo "ERROR: Unknown argument: -${OPTARG}"
      usage
      exit 1
      ;;
  esac
done
shift $((OPTIND - 1))

if [[ $# -gt 0 ]]; then
  echo "ERROR: Unexpected positional argument: $1"
  usage
  exit 1
fi

require_command helm

if ! helm repo list | awk '{print $1}' | grep -qx "${GITLAB_HELM_REPO_NAME}"; then
  echo "Adding Helm repo '${GITLAB_HELM_REPO_NAME}'..."
  helm repo add "${GITLAB_HELM_REPO_NAME}" "${GITLAB_HELM_REPO_URL}"
fi

RELEASE_JSON="$(helm list --kube-context "${KUBE_CONTEXT}" --namespace "${NAMESPACE}" \
  --filter "^${RELEASE_NAME}$" --output json)"
CURRENT_VERSION="$(sed -nE 's/.*"chart"[[:space:]]*:[[:space:]]*"[^"[:space:]]+-([0-9][^"]*)".*/\1/p' <<< "${RELEASE_JSON}" | head -1)"
CURRENT_APP_VERSION="$(sed -nE 's/.*"app_version"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' <<< "${RELEASE_JSON}" | head -1)"

if [[ -z "${CURRENT_VERSION}" ]]; then
  echo "ERROR: Helm release '${RELEASE_NAME}' was not found in namespace '${NAMESPACE}' on context '${KUBE_CONTEXT}'."
  exit 1
fi

echo "Updating Helm repo '${GITLAB_HELM_REPO_NAME}'..."
helm repo update "${GITLAB_HELM_REPO_NAME}"

LATEST_ROW="$(helm search repo "${GITLAB_RUNNER_CHART_REF}" --versions | awk 'NR == 2 { print $2 "\t" $3 }')"
LATEST_VERSION="$(awk '{ print $1 }' <<< "${LATEST_ROW}")"
LATEST_APP_VERSION="$(awk '{ print $2 }' <<< "${LATEST_ROW}")"

if [[ -z "${LATEST_VERSION}" ]]; then
  echo "ERROR: Could not find the latest chart version for ${GITLAB_RUNNER_CHART_REF}."
  exit 1
fi

IFS=. read -r CURRENT_MAJOR CURRENT_MINOR CURRENT_PATCH <<< "${CURRENT_VERSION}"
IFS=. read -r LATEST_MAJOR LATEST_MINOR LATEST_PATCH <<< "${LATEST_VERSION}"

echo "Current runner chart: ${CURRENT_VERSION} (app ${CURRENT_APP_VERSION:-unknown})"
echo "Latest runner chart:  ${LATEST_VERSION} (app ${LATEST_APP_VERSION:-unknown})"

if [[ "${CURRENT_VERSION}" == "${LATEST_VERSION}" ]]; then
  echo "Already up to date."
  exit 0
fi

if [[ "${CURRENT_MAJOR}" != "${LATEST_MAJOR}" ]]; then
  echo "Upgrade type: major"
  if [[ "${APPLY}" == "true" && "${ALLOW_MAJOR}" != "true" ]]; then
    echo "ERROR: Refusing to apply a major upgrade without -M."
    exit 2
  fi
elif [[ "${CURRENT_MINOR}" != "${LATEST_MINOR}" ]]; then
  echo "Upgrade type: minor"
  if [[ "${APPLY}" == "true" && "${ALLOW_MINOR}" != "true" && "${ALLOW_MAJOR}" != "true" ]]; then
    echo "ERROR: Refusing to apply a minor upgrade without -m."
    exit 2
  fi
else
  echo "Upgrade type: patch"
fi

if [[ "${APPLY}" != "true" ]]; then
  echo "Run with -a to upgrade '${RELEASE_NAME}' while retaining its current Helm values."
  exit 0
fi

echo "Upgrading runner release '${RELEASE_NAME}'..."
helm upgrade "${RELEASE_NAME}" "${GITLAB_RUNNER_CHART_REF}" \
  --kube-context "${KUBE_CONTEXT}" \
  --namespace "${NAMESPACE}" \
  --reuse-values \
  --version "${LATEST_VERSION}" \
  --wait \
  --timeout "${HELM_TIMEOUT}"

echo "Runner upgrade completed: ${CURRENT_VERSION} -> ${LATEST_VERSION}"
