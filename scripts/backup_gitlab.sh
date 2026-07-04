#!/bin/bash

# Create a GitLab Helm toolbox backup and copy the archive out of object storage.

set -eo pipefail
[[ "${TRACE}" ]] && set -x

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

NAMESPACE="${NAMESPACE:-gitlab}"
RELEASE_NAME="${RELEASE_NAME:-gitlab}"
K3D_CLUSTER_NAME="${K3D_CLUSTER_NAME:-gitlab-dev}"
KUBE_CONTEXT="${KUBE_CONTEXT:-k3d-${K3D_CLUSTER_NAME}}"
BACKUP_BUCKET="${BACKUP_BUCKET:-gitlab-backups}"
BACKUP_DIR="${BACKUP_DIR:-${PROJECT_ROOT}/.backups}"
BACKUP_UTILITY_ARGS="${BACKUP_UTILITY_ARGS:-}"

function usage() {
  local exit_code="${1:-1}"

  cat <<EOF
Usage: $0 [-d BACKUP_DIR] [-h]

Creates a GitLab backup with the Toolbox pod, downloads the newest
gitlab-backups object, and stores it on the host.

Options:
  -d BACKUP_DIR  Host directory for copied backup archives (default: .backups)
  -h             Show this help.

Environment:
  NAMESPACE           Kubernetes namespace (default: gitlab)
  RELEASE_NAME        Helm release name (default: gitlab)
  KUBE_CONTEXT        Kubernetes context (default: k3d-gitlab-dev)
  BACKUP_BUCKET       Object storage backup bucket (default: gitlab-backups)
  BACKUP_DIR          Host backup directory (default: .backups)
  BACKUP_UTILITY_ARGS Extra arguments passed to backup-utility
EOF
  exit "${exit_code}"
}

function require_command() {
  local name="$1"

  if ! command -v "${name}" >/dev/null 2>&1; then
    echo "ERROR: ${name} is required but not installed."
    exit 1
  fi
}

function base64_decode() {
  if base64 --decode >/dev/null 2>&1 <<< ""; then
    base64 --decode
  else
    base64 -D
  fi
}

function running_toolbox_pod() {
  kubectl --context "${KUBE_CONTEXT}" -n "${NAMESPACE}" get pod \
    -l "release=${RELEASE_NAME},app=toolbox" \
    --field-selector=status.phase=Running \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true
}

function rails_secret_name() {
  kubectl --context "${KUBE_CONTEXT}" -n "${NAMESPACE}" get secrets \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null \
    | awk '/rails-secret$/ { print; exit }'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -d)
      BACKUP_DIR="${2:-}"
      shift 2
      ;;
    -h)
      usage 0
      ;;
    *)
      echo "ERROR: Unknown argument: $1"
      usage
      ;;
  esac
done

if [[ -z "${BACKUP_DIR}" ]]; then
  echo "ERROR: -d BACKUP_DIR cannot be empty."
  usage
fi

require_command kubectl

if ! kubectl config get-contexts "${KUBE_CONTEXT}" > /dev/null 2>&1; then
  echo "ERROR: Kubernetes context '${KUBE_CONTEXT}' was not found."
  exit 1
fi

TOOLBOX_POD="$(running_toolbox_pod)"
if [[ -z "${TOOLBOX_POD}" ]]; then
  echo "ERROR: No running toolbox pod found for release '${RELEASE_NAME}' in namespace '${NAMESPACE}'."
  echo "Run: bash scripts/check_status.sh"
  exit 1
fi

mkdir -p "${BACKUP_DIR}"

echo "Using toolbox pod: ${TOOLBOX_POD}"
echo "Saving Rails secrets..."

RAILS_SECRET_NAME="$(rails_secret_name)"
if [[ -z "${RAILS_SECRET_NAME}" ]]; then
  echo "ERROR: Could not find a Rails secret ending in 'rails-secret' in namespace '${NAMESPACE}'."
  exit 1
fi

RAILS_SECRET_FILE="${BACKUP_DIR}/${RELEASE_NAME}-rails-secrets.yaml"
kubectl --context "${KUBE_CONTEXT}" -n "${NAMESPACE}" get secret "${RAILS_SECRET_NAME}" \
  -o jsonpath="{.data['secrets\.yml']}" \
  | base64_decode > "${RAILS_SECRET_FILE}"

echo "Rails secrets copied to: ${RAILS_SECRET_FILE}"
echo "Creating GitLab backup in s3://${BACKUP_BUCKET}/ ..."

kubectl --context "${KUBE_CONTEXT}" -n "${NAMESPACE}" exec "${TOOLBOX_POD}" -c toolbox -- \
  sh -lc "backup-utility ${BACKUP_UTILITY_ARGS}"

echo "Finding newest backup archive..."
BACKUP_OBJECT="$(
  kubectl --context "${KUBE_CONTEXT}" -n "${NAMESPACE}" exec "${TOOLBOX_POD}" -c toolbox -- \
    sh -lc "s3cmd ls 's3://${BACKUP_BUCKET}/' | awk '\$4 ~ /_gitlab_backup\\.tar$/ { print \$4 }' | sort | tail -n 1" \
    2>/dev/null || true
)"

if [[ -z "${BACKUP_OBJECT}" ]]; then
  echo "ERROR: Could not find a backup archive in s3://${BACKUP_BUCKET}/."
  echo "Check object storage from the toolbox pod with: s3cmd ls s3://${BACKUP_BUCKET}/"
  exit 1
fi

BACKUP_FILE="${BACKUP_OBJECT##*/}"
REMOTE_TMP="/tmp/${BACKUP_FILE}"
LOCAL_BACKUP="${BACKUP_DIR}/${BACKUP_FILE}"

echo "Downloading ${BACKUP_OBJECT} to toolbox temp path..."
kubectl --context "${KUBE_CONTEXT}" -n "${NAMESPACE}" exec "${TOOLBOX_POD}" -c toolbox -- \
  sh -lc "rm -f '${REMOTE_TMP}' && s3cmd get '${BACKUP_OBJECT}' '${REMOTE_TMP}'"

echo "Copying backup to host: ${LOCAL_BACKUP}"
kubectl --context "${KUBE_CONTEXT}" -n "${NAMESPACE}" cp \
  -c toolbox \
  "${TOOLBOX_POD}:${REMOTE_TMP}" \
  "${LOCAL_BACKUP}"

kubectl --context "${KUBE_CONTEXT}" -n "${NAMESPACE}" exec "${TOOLBOX_POD}" -c toolbox -- \
  rm -f "${REMOTE_TMP}"

echo "Backup copied to: ${LOCAL_BACKUP}"
