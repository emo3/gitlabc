#!/bin/bash

# Restore a GitLab Helm toolbox backup from a host backup directory.

set -eo pipefail
[[ "${TRACE}" ]] && set -x

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

NAMESPACE="${NAMESPACE:-gitlab}"
RELEASE_NAME="${RELEASE_NAME:-gitlab}"
K3D_CLUSTER_NAME="${K3D_CLUSTER_NAME:-gitlab-dev}"
KUBE_CONTEXT="${KUBE_CONTEXT:-k3d-${K3D_CLUSTER_NAME}}"
BACKUP_DIR="${BACKUP_DIR:-${PROJECT_ROOT}/.backups}"
BACKUP_TAR="${BACKUP_TAR:-}"
RAILS_SECRETS="${RAILS_SECRETS:-}"
LIST_ONLY=false
SCALED_DOWN=false
REMOTE_TMP=""
TOOLBOX_POD=""

function usage() {
  local exit_code="${1:-1}"

  cat <<EOF
Usage: $0 [options]

Restores a GitLab backup archive into the local Helm deployment.
By default, the newest *_gitlab_backup.tar in BACKUP_DIR is used.

Options:
  -d BACKUP_DIR       Host backup directory (default: .backups)
  -f BACKUP_TAR       Specific backup archive to restore
  -s RAILS_SECRETS    Rails secrets file (default: auto-detect in BACKUP_DIR)
  -l                  List available backup archives and exit
  -h                  Show this help

Environment:
  NAMESPACE           Kubernetes namespace (default: gitlab)
  RELEASE_NAME        Helm release name (default: gitlab)
  KUBE_CONTEXT        Kubernetes context (default: k3d-gitlab-dev)
  BACKUP_DIR          Host backup directory (default: .backups)
  BACKUP_TAR          Specific backup archive to restore
  RAILS_SECRETS       Rails secrets file
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

function find_backups() {
  local backups

  shopt -s nullglob
  backups=("${BACKUP_DIR}"/*_gitlab_backup.tar)
  shopt -u nullglob

  if [[ "${#backups[@]}" -gt 0 ]]; then
    ls -t "${backups[@]}"
  fi
}

function newest_backup() {
  find_backups | head -1
}

function list_backups() {
  local index=1
  local backup

  if [[ ! -d "${BACKUP_DIR}" ]]; then
    echo "ERROR: Backup directory does not exist: ${BACKUP_DIR}"
    exit 1
  fi

  echo "Available backups in ${BACKUP_DIR}:"
  echo ""

  while IFS= read -r backup; do
    printf "%2d  %s\n" "${index}" "$(basename "${backup}")"
    index=$((index + 1))
  done < <(find_backups)

  if [[ "${index}" -eq 1 ]]; then
    echo "No *_gitlab_backup.tar files found."
  fi
}

function detect_rails_secrets() {
  local candidate

  for candidate in \
    "${BACKUP_DIR}/${RELEASE_NAME}-rails-secrets.yaml" \
    "${BACKUP_DIR}/gitlab-rails-secrets.yaml"
  do
    if [[ -f "${candidate}" ]]; then
      echo "${candidate}"
      return
    fi
  done
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

function scale_gitlab() {
  local replicas="$1"

  kubectl --context "${KUBE_CONTEXT}" -n "${NAMESPACE}" scale deploy \
    -l "app=sidekiq,release=${RELEASE_NAME}" \
    --replicas="${replicas}"
  kubectl --context "${KUBE_CONTEXT}" -n "${NAMESPACE}" scale deploy \
    -l "app=webservice,release=${RELEASE_NAME}" \
    --replicas="${replicas}"
}

function check_status() {
  NAMESPACE="${NAMESPACE}" KUBE_CONTEXT="${KUBE_CONTEXT}" \
    bash "${PROJECT_ROOT}/scripts/check_status.sh"
}

function cleanup() {
  local exit_code=$?

  if [[ "${SCALED_DOWN}" == "true" ]]; then
    echo "Scaling GitLab webservice and sidekiq back to 1 replica..."
    scale_gitlab 1 || true
  fi

  if [[ -n "${TOOLBOX_POD}" && -n "${REMOTE_TMP}" ]]; then
    kubectl --context "${KUBE_CONTEXT}" -n "${NAMESPACE}" exec "${TOOLBOX_POD}" -c toolbox -- \
      rm -f "${REMOTE_TMP}" >/dev/null 2>&1 || true
  fi

  exit "${exit_code}"
}

while getopts ":d:f:s:lh" opt; do
  case "${opt}" in
    d)
      BACKUP_DIR="${OPTARG}"
      ;;
    f)
      BACKUP_TAR="${OPTARG}"
      ;;
    s)
      RAILS_SECRETS="${OPTARG}"
      ;;
    l)
      LIST_ONLY=true
      ;;
    h)
      usage 0
      ;;
    :)
      echo "ERROR: -${OPTARG} requires an argument."
      usage
      ;;
    \?)
      echo "ERROR: Unknown argument: -${OPTARG}"
      usage
      ;;
  esac
done
shift $((OPTIND - 1))

if [[ $# -gt 0 ]]; then
  echo "ERROR: Unexpected positional argument: $1"
  usage
fi

if [[ -z "${BACKUP_DIR}" ]]; then
  echo "ERROR: -d BACKUP_DIR cannot be empty."
  usage
fi

if [[ "${LIST_ONLY}" == "true" ]]; then
  list_backups
  exit 0
fi

require_command kubectl

if [[ ! -d "${BACKUP_DIR}" ]]; then
  echo "ERROR: Backup directory does not exist: ${BACKUP_DIR}"
  exit 1
fi

if [[ -z "${BACKUP_TAR}" ]]; then
  BACKUP_TAR="$(newest_backup)"
fi

if [[ -n "${BACKUP_TAR}" && ! -f "${BACKUP_TAR}" && -f "${BACKUP_DIR}/${BACKUP_TAR}" ]]; then
  BACKUP_TAR="${BACKUP_DIR}/${BACKUP_TAR}"
fi

if [[ -z "${BACKUP_TAR}" ]]; then
  echo "ERROR: No *_gitlab_backup.tar files found in ${BACKUP_DIR}."
  echo "Run '$0 -l' to inspect available backups."
  exit 1
fi

if [[ ! -f "${BACKUP_TAR}" ]]; then
  echo "ERROR: Backup archive does not exist: ${BACKUP_TAR}"
  exit 1
fi

if [[ -z "${RAILS_SECRETS}" ]]; then
  RAILS_SECRETS="$(detect_rails_secrets)"
fi

if [[ -z "${RAILS_SECRETS}" || ! -f "${RAILS_SECRETS}" ]]; then
  echo "ERROR: Rails secrets file was not found."
  echo "Expected ${BACKUP_DIR}/${RELEASE_NAME}-rails-secrets.yaml or ${BACKUP_DIR}/gitlab-rails-secrets.yaml."
  echo "Pass a specific file with: -s /path/to/gitlab-rails-secrets.yaml"
  exit 1
fi

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

RAILS_SECRET="$(rails_secret_name)"
if [[ -z "${RAILS_SECRET}" ]]; then
  echo "ERROR: Could not find a Rails secret ending in 'rails-secret' in namespace '${NAMESPACE}'."
  exit 1
fi

BACKUP_FILE="$(basename "${BACKUP_TAR}")"
REMOTE_TMP="/tmp/${BACKUP_FILE}"

echo "This will overwrite GitLab data in namespace '${NAMESPACE}' on context '${KUBE_CONTEXT}'."
echo "Backup archive: ${BACKUP_TAR}"
echo "Rails secrets:  ${RAILS_SECRETS}"
echo "Rails secret:   ${RAILS_SECRET}"
echo "Toolbox pod:    ${TOOLBOX_POD}"
echo ""

trap cleanup EXIT

echo "Restoring Rails secrets..."
kubectl --context "${KUBE_CONTEXT}" -n "${NAMESPACE}" delete secret "${RAILS_SECRET}"
kubectl --context "${KUBE_CONTEXT}" -n "${NAMESPACE}" create secret generic "${RAILS_SECRET}" \
  --from-file=secrets.yml="${RAILS_SECRETS}"

echo "Restarting GitLab pods so they pick up restored Rails secrets..."
kubectl --context "${KUBE_CONTEXT}" -n "${NAMESPACE}" delete pods \
  -l "app=sidekiq,release=${RELEASE_NAME}"
kubectl --context "${KUBE_CONTEXT}" -n "${NAMESPACE}" delete pods \
  -l "app=webservice,release=${RELEASE_NAME}"
kubectl --context "${KUBE_CONTEXT}" -n "${NAMESPACE}" delete pods \
  -l "app=toolbox,release=${RELEASE_NAME}"

check_status

TOOLBOX_POD="$(running_toolbox_pod)"
if [[ -z "${TOOLBOX_POD}" ]]; then
  echo "ERROR: No running toolbox pod found after restart."
  exit 1
fi

echo "Copying ${BACKUP_FILE} into toolbox pod..."
kubectl --context "${KUBE_CONTEXT}" -n "${NAMESPACE}" cp -c toolbox \
  "${BACKUP_TAR}" \
  "${TOOLBOX_POD}:${REMOTE_TMP}"

echo "Scaling GitLab webservice and sidekiq down for restore..."
scale_gitlab 0
SCALED_DOWN=true

echo "Running GitLab restore..."
kubectl --context "${KUBE_CONTEXT}" -n "${NAMESPACE}" exec "${TOOLBOX_POD}" -c toolbox -- \
  env GITLAB_ASSUME_YES=1 backup-utility --restore -f "file://${REMOTE_TMP}"

echo "Scaling GitLab webservice and sidekiq back to 1 replica..."
scale_gitlab 1
SCALED_DOWN=false

echo "Waiting for GitLab to become healthy..."
check_status

echo "Restore complete."
