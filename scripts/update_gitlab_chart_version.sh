#!/bin/bash

# Check the latest GitLab Helm chart version and optionally update the local
# deploy script's pinned GITLAB_CHART_VERSION.

set -eo pipefail
[[ "${TRACE}" ]] && set -x

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
DEPLOY_SCRIPT="${DEPLOY_SCRIPT:-${PROJECT_ROOT}/scripts/deploy_gitlab.sh}"

GITLAB_HELM_REPO_NAME="${GITLAB_HELM_REPO_NAME:-gitlab}"
GITLAB_HELM_REPO_URL="${GITLAB_HELM_REPO_URL:-https://charts.gitlab.io/}"
GITLAB_CHART_REF="${GITLAB_CHART_REF:-${GITLAB_HELM_REPO_NAME}/gitlab}"

APPLY=false
ALLOW_MINOR=false
ALLOW_MAJOR=false

function usage() {
  cat <<'USAGE'
Usage: bash scripts/update_gitlab_chart_version.sh [-a] [-m] [-M]

Checks the latest gitlab/gitlab Helm chart version.

Options:
  -a  Update scripts/deploy_gitlab.sh with the latest chart version.
  -m  Permit -a across minor versions, such as 10.1.x -> 10.2.x.
  -M  Permit -a across major versions, such as 10.x -> 11.x.
  -h  Show this help.
USAGE
}

while getopts ":amMh" opt; do
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

if [[ ! -f "${DEPLOY_SCRIPT}" ]]; then
  echo "ERROR: Deploy script not found at ${DEPLOY_SCRIPT}."
  exit 1
fi

CURRENT_VERSION="$(sed -nE 's/^GITLAB_CHART_VERSION="\$\{GITLAB_CHART_VERSION:-([^}]+)\}"$/\1/p' "${DEPLOY_SCRIPT}")"
if [[ -z "${CURRENT_VERSION}" ]]; then
  echo "ERROR: Could not find pinned GITLAB_CHART_VERSION in ${DEPLOY_SCRIPT}."
  exit 1
fi

if ! helm repo list | awk '{print $1}' | grep -qx "${GITLAB_HELM_REPO_NAME}"; then
  echo "Adding Helm repo '${GITLAB_HELM_REPO_NAME}'..."
  helm repo add "${GITLAB_HELM_REPO_NAME}" "${GITLAB_HELM_REPO_URL}"
fi

echo "Updating Helm repo '${GITLAB_HELM_REPO_NAME}'..."
helm repo update "${GITLAB_HELM_REPO_NAME}"

LATEST_ROW="$(helm search repo "${GITLAB_CHART_REF}" --versions | awk 'NR == 2 { print $2 "\t" $3 }')"
LATEST_VERSION="$(awk '{ print $1 }' <<< "${LATEST_ROW}")"
LATEST_APP_VERSION="$(awk '{ print $2 }' <<< "${LATEST_ROW}")"

if [[ -z "${LATEST_VERSION}" ]]; then
  echo "ERROR: Could not find latest chart version for ${GITLAB_CHART_REF}."
  exit 1
fi

IFS=. read -r CURRENT_MAJOR CURRENT_MINOR CURRENT_PATCH <<< "${CURRENT_VERSION}"
IFS=. read -r LATEST_MAJOR LATEST_MINOR LATEST_PATCH <<< "${LATEST_VERSION}"

echo "Current chart version: ${CURRENT_VERSION}"
echo "Latest chart version:  ${LATEST_VERSION}"
echo "Latest GitLab app:     ${LATEST_APP_VERSION}"

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
  echo "Run with -a to update ${DEPLOY_SCRIPT}."
  exit 0
fi

TMP_FILE="$(mktemp)"
awk -v latest="${LATEST_VERSION}" '
  /^GITLAB_CHART_VERSION="\$\{GITLAB_CHART_VERSION:-[^}]+\}"$/ {
    print "GITLAB_CHART_VERSION=\"${GITLAB_CHART_VERSION:-" latest "}\""
    next
  }
  { print }
' "${DEPLOY_SCRIPT}" > "${TMP_FILE}"
mv "${TMP_FILE}" "${DEPLOY_SCRIPT}"
chmod +x "${DEPLOY_SCRIPT}"

echo "Updated ${DEPLOY_SCRIPT}: ${CURRENT_VERSION} -> ${LATEST_VERSION}"
echo "Deploy with:"
echo "bash scripts/deploy_gitlab.sh"
