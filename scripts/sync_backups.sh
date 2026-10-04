#!/bin/bash

# Pull a GitLab .backups directory from either member of the primary/standby pair.

set -euo pipefail
[[ -n "${TRACE:-}" ]] && set -x

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
GITLAB_ENV_FILE="${GITLAB_ENV_FILE:-${PROJECT_ROOT}/.gitlab.env}"
if [[ -f "${GITLAB_ENV_FILE}" ]]; then
  # shellcheck disable=SC1090
  source "${GITLAB_ENV_FILE}"
fi

GITLAB_PRIMARY_HOST="${GITLAB_PRIMARY_HOST:-almalinxo}"
GITLAB_STANDBY_HOST="${GITLAB_STANDBY_HOST:-almalt}"
GITLAB_PRIMARY_SSH="${GITLAB_PRIMARY_SSH:-192.168.86.80}"
GITLAB_STANDBY_SSH="${GITLAB_STANDBY_SSH:-192.168.86.141}"
GITLAB_PEER_PROJECT_ROOT="${GITLAB_PEER_PROJECT_ROOT:-${PROJECT_ROOT}}"
BACKUP_DIR="${BACKUP_DIR:-${PROJECT_ROOT}/.backups}"
DRY_RUN=false
DELETE=false

usage() {
  cat <<EOF
Usage: $0 [options] <80|.80|141|.141|primary|standby|HOST>

Pull .backups from the selected GitLab host into the local .backups directory.
Existing local files are updated, but never deleted unless --delete is given.

Options:
  -d BACKUP_DIR  Local destination (default: .backups)
  -n             Show what rsync would change without copying
  --delete       Mirror the remote directory, deleting local-only files
  -h             Show this help

Source selectors:
  80, .80, primary, ${GITLAB_PRIMARY_HOST}, or ${GITLAB_PRIMARY_SSH}
  141, .141, standby, ${GITLAB_STANDBY_HOST}, or ${GITLAB_STANDBY_SSH}

Environment:
  BACKUP_DIR                Local destination directory
  GITLAB_PEER_PROJECT_ROOT  GitLab project path on the source host
  GITLAB_PRIMARY_SSH        SSH destination for the .80 host
  GITLAB_STANDBY_SSH        SSH destination for the .141 host
EOF
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "ERROR: $1 is required but not installed." >&2
    exit 1
  }
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -d) BACKUP_DIR="$2"; shift 2 ;;
    -n) DRY_RUN=true; shift ;;
    --delete) DELETE=true; shift ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "ERROR: Unknown option: $1" >&2; usage >&2; exit 2 ;;
    *)
      if [[ -n "${SOURCE_SELECTOR:-}" ]]; then
        echo "ERROR: Specify exactly one source host." >&2
        usage >&2
        exit 2
      fi
      SOURCE_SELECTOR="$1"
      shift
      ;;
  esac
done

[[ -n "${SOURCE_SELECTOR:-}" ]] || { usage >&2; exit 2; }

case "${SOURCE_SELECTOR}" in
  80|.80|primary|"${GITLAB_PRIMARY_HOST}"|"${GITLAB_PRIMARY_SSH}") SOURCE_SSH="${GITLAB_PRIMARY_SSH}" ;;
  141|.141|standby|"${GITLAB_STANDBY_HOST}"|"${GITLAB_STANDBY_SSH}") SOURCE_SSH="${GITLAB_STANDBY_SSH}" ;;
  *)
    echo "ERROR: Source must be .80/.141 (or a configured host alias), not '${SOURCE_SELECTOR}'." >&2
    exit 2
    ;;
esac

require_command rsync
require_command ssh
mkdir -p "${BACKUP_DIR}"

RSYNC_OPTIONS=(-a --human-readable --info=NAME,STATS2 -e "ssh -o BatchMode=yes -o ConnectTimeout=10")
[[ "${DRY_RUN}" == true ]] && RSYNC_OPTIONS+=(--dry-run)
[[ "${DELETE}" == true ]] && RSYNC_OPTIONS+=(--delete)

echo "Syncing ${SOURCE_SSH}:${GITLAB_PEER_PROJECT_ROOT}/.backups/ to ${BACKUP_DIR}/"
rsync "${RSYNC_OPTIONS[@]}" \
  "${SOURCE_SSH}:${GITLAB_PEER_PROJECT_ROOT}/.backups/" "${BACKUP_DIR}/"
