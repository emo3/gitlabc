#!/bin/bash

# Import a GitHub repository into a local GitLab group.

set -eo pipefail
[[ "${TRACE}" ]] && set -x

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CODE_ROOT="$(cd "${PROJECT_ROOT}/.." && pwd)"

GITLAB_ENV_FILE="${GITLAB_ENV_FILE:-${PROJECT_ROOT}/.gitlab.env}"
if [[ -f "${GITLAB_ENV_FILE}" ]]; then
  # shellcheck disable=SC1090
  source "${GITLAB_ENV_FILE}"
fi
GITLAB_DOMAIN="${GITLAB_DOMAIN:-192.168.86.50.nip.io}"
GITLAB_HOST="${GITLAB_HOST:-gitlab.${GITLAB_DOMAIN}}"
GITLAB_GROUP="${GITLAB_GROUP:-netcool}"
GITLAB_VISIBILITY="${GITLAB_VISIBILITY:-internal}"
GITHUB_OWNER="${GITHUB_OWNER:-emo3}"
GLAB_CONFIG_DIR="${GLAB_CONFIG_DIR:-${XDG_CONFIG_HOME:-${CODE_ROOT}/.glab-config}/glab-cli}"
TMP_ROOT="${TMP_ROOT:-${TMPDIR:-/tmp}}"
DESCRIPTION=""
DEFAULT_BRANCH=""
KEEP_MIRROR="false"
SOURCE_REPO=""
GITHUB_AUTH_HEADER=""
GITHUB_REPO_NAME=""
PROJECT_NAME=""
PROJECT_CHANGED="false"
REFS_CHANGED="false"
DEFAULT_BRANCH_CHANGED="false"

function usage() {
  local exit_code="${1:-1}"

  cat <<EOF
Usage: $0 -r SOURCE [-n PROJECT_NAME] [-g GROUP] [-v internal|private|public] [-b BRANCH] [-d TEXT] [-k]

Imports a GitHub repository into a GitLab project, then pushes branches and tags.

SOURCE can be:
  PROJECT_NAME
  OWNER/PROJECT_NAME
  https://github.com/OWNER/PROJECT_NAME
  https://github.com/OWNER/PROJECT_NAME.git

Environment:
  GITLAB_HOST       GitLab host (default: gitlab.<GITLAB_DOMAIN>)
  GITLAB_GROUP      GitLab group/namespace (default: netcool)
  GITLAB_VISIBILITY Project visibility (default: internal)
  GITHUB_OWNER      Owner used when SOURCE is only a project name (default: emo3)
  GITHUB_TOKEN      GitHub token for private repositories (or use GH_TOKEN)
  GLAB_CONFIG_DIR   glab config directory (default: ../.glab-config/glab-cli from this repo)
  TMP_ROOT          Temporary mirror root (default: TMPDIR or /tmp)

Examples:
  $0 -r tcr_db2
  $0 -r emo3/tcr_db2
  $0 -r https://github.com/emo3/tcr_db2.git -g netcool

Options:
  -r SOURCE        GitHub source repository. Required.
  -n PROJECT_NAME  GitLab project name. Defaults to the GitHub repo name.
  -g GROUP         GitLab group/namespace. Defaults to GITLAB_GROUP.
  -v VISIBILITY    internal, private, or public. Defaults to GITLAB_VISIBILITY.
  -b BRANCH        Default branch. Defaults to the GitHub default branch.
  -d TEXT          GitLab project description.
  -k               Keep the temporary mirror directory.
  -h               Show this help.
EOF
  exit "${exit_code}"
}

function require_command() {
  local name="$1"

  if ! command -v "${name}" >/dev/null 2>&1; then
    echo "ERROR: ${name} is required."
    exit 1
  fi
}

function verify_glab_auth() {
  if ! GLAB_CONFIG_DIR="${GLAB_CONFIG_DIR}" GITLAB_HOST="${GITLAB_HOST}" \
    glab api user >/dev/null 2>&1; then
    echo "ERROR: Could not authenticate to GitLab host '${GITLAB_HOST}'." >&2
    echo "Run: GLAB_CONFIG_DIR='${GLAB_CONFIG_DIR}' glab auth login --hostname '${GITLAB_HOST}'" >&2
    exit 1
  fi
}

function validate_visibility() {
  case "${GITLAB_VISIBILITY}" in
    internal|private|public)
      ;;
    *)
      echo "ERROR: -v must be internal, private, or public."
      exit 1
      ;;
  esac
}

function normalize_source() {
  local source="$1"
  local path

  case "${source}" in
    https://github.com/*)
      path="${source#https://github.com/}"
      path="${path%.git}"
      ;;
    git@github.com:*)
      path="${source#git@github.com:}"
      path="${path%.git}"
      ;;
    */*)
      path="${source%.git}"
      ;;
    *)
      path="${GITHUB_OWNER}/${source%.git}"
      ;;
  esac

  if [[ "${path}" != */* ]]; then
    echo "ERROR: Could not determine GitHub owner/repo from '${source}'."
    exit 1
  fi

  GITHUB_OWNER="${path%%/*}"
  GITHUB_REPO_NAME="${path##*/}"
  PROJECT_NAME="${PROJECT_NAME:-${GITHUB_REPO_NAME}}"
  SOURCE_REPO="https://github.com/${GITHUB_OWNER}/${GITHUB_REPO_NAME}.git"
}

function configure_github_auth() {
  local token="${GITHUB_TOKEN:-${GH_TOKEN:-}}"

  if [[ -z "${token}" ]] && command -v gh >/dev/null 2>&1; then
    token="$(gh auth token 2>/dev/null || true)"
  fi

  if [[ -n "${token}" ]]; then
    GITHUB_AUTH_HEADER="Authorization: Bearer ${token}"
  fi
}

function github_git() {
  if [[ -n "${GITHUB_AUTH_HEADER}" ]]; then
    git -c "http.https://github.com/.extraheader=${GITHUB_AUTH_HEADER}" "$@"
  else
    git "$@"
  fi
}

function detect_default_branch() {
  local symref
  local master_ref

  if [[ -n "${DEFAULT_BRANCH}" ]]; then
    return 0
  fi

  symref="$(github_git ls-remote --symref "${SOURCE_REPO}" HEAD 2>/dev/null | awk '/^ref:/ { sub("refs/heads/", "", $2); print $2; exit }')"
  if [[ -n "${symref}" ]]; then
    DEFAULT_BRANCH="${symref}"
    return 0
  fi

  master_ref="$(github_git ls-remote --heads "${SOURCE_REPO}" master 2>/dev/null)"
  if [[ -n "${master_ref}" ]]; then
    DEFAULT_BRANCH="master"
  else
    DEFAULT_BRANCH="main"
  fi
}

function project_exists() {
  GLAB_CONFIG_DIR="${GLAB_CONFIG_DIR}" GITLAB_HOST="${GITLAB_HOST}" \
    glab repo view "${GITLAB_HOST}/${GITLAB_GROUP}/${PROJECT_NAME}" >/dev/null 2>&1
}

function project_api_path() {
  local group_path

  group_path="${GITLAB_GROUP//\//%2F}"
  echo "projects/${group_path}%2F${PROJECT_NAME}"
}

function group_api_path() {
  local group_path

  group_path="${GITLAB_GROUP//\//%2F}"
  echo "groups/${group_path}"
}

function target_repo_url() {
  echo "https://${GITLAB_HOST}/${GITLAB_GROUP}/${PROJECT_NAME}.git"
}

function create_or_update_project() {
  local project_path="${GITLAB_GROUP}/${PROJECT_NAME}"
  local namespace_id
  local current_description
  local current_visibility

  if project_exists; then
    echo "Project already exists: https://${GITLAB_HOST}/${project_path}"
  else
    echo "Creating GitLab project: ${project_path}"
    namespace_id="$(
      GLAB_CONFIG_DIR="${GLAB_CONFIG_DIR}" GITLAB_HOST="${GITLAB_HOST}" \
        glab api "$(group_api_path)" \
        | jq -r '.id // empty'
    )"

    if [[ -z "${namespace_id}" ]]; then
      echo "ERROR: Could not resolve GitLab group '${GITLAB_GROUP}'."
      exit 1
    fi

    GLAB_CONFIG_DIR="${GLAB_CONFIG_DIR}" GITLAB_HOST="${GITLAB_HOST}" \
      glab api projects \
        -X POST \
        -f "name=${PROJECT_NAME}" \
        -f "path=${PROJECT_NAME}" \
        -f "namespace_id=${namespace_id}" \
        -f "visibility=${GITLAB_VISIBILITY}" \
        -f "description=${DESCRIPTION}" >/dev/null
    PROJECT_CHANGED="true"
  fi

  current_visibility="$(
    GLAB_CONFIG_DIR="${GLAB_CONFIG_DIR}" GITLAB_HOST="${GITLAB_HOST}" \
      glab api "$(project_api_path)" \
      | jq -r '.visibility // empty'
  )"
  current_description="$(
    GLAB_CONFIG_DIR="${GLAB_CONFIG_DIR}" GITLAB_HOST="${GITLAB_HOST}" \
      glab api "$(project_api_path)" \
      | jq -r '.description // empty'
  )"

  if [[ "${current_visibility}" != "${GITLAB_VISIBILITY}" || "${current_description}" != "${DESCRIPTION}" ]]; then
    echo "Updating GitLab project settings..."
    GLAB_CONFIG_DIR="${GLAB_CONFIG_DIR}" GITLAB_HOST="${GITLAB_HOST}" \
      glab api "$(project_api_path)" \
        -X PUT \
        -f "visibility=${GITLAB_VISIBILITY}" \
        -f "description=${DESCRIPTION}" >/dev/null
    PROJECT_CHANGED="true"
  fi
}

function update_default_branch() {
  local current_default_branch

  current_default_branch="$(
    GLAB_CONFIG_DIR="${GLAB_CONFIG_DIR}" GITLAB_HOST="${GITLAB_HOST}" \
      glab api "$(project_api_path)" \
      | jq -r '.default_branch // empty'
  )"

  if [[ "${current_default_branch}" != "${DEFAULT_BRANCH}" ]]; then
    echo "Updating default branch to ${DEFAULT_BRANCH}..."
    GLAB_CONFIG_DIR="${GLAB_CONFIG_DIR}" GITLAB_HOST="${GITLAB_HOST}" \
      glab api "$(project_api_path)" \
        -X PUT \
        -f "default_branch=${DEFAULT_BRANCH}" >/dev/null
    DEFAULT_BRANCH_CHANGED="true"
  fi
}

function refs_snapshot() {
  local repo="$1"

  if [[ "${repo}" == "${SOURCE_REPO}" ]]; then
    github_git ls-remote "${repo}" 'refs/heads/*' 'refs/tags/*'
  else
    git ls-remote "${repo}" 'refs/heads/*' 'refs/tags/*'
  fi \
    | awk '$2 !~ /\^\{\}$/ { print $1 "\t" $2 }' \
    | sort
}

function refs_are_current() {
  local target_repo="$1"
  local source_refs
  local target_refs

  source_refs="$(refs_snapshot "${SOURCE_REPO}")"
  target_refs="$(refs_snapshot "${target_repo}" 2>/dev/null || true)"

  [[ -n "${source_refs}" && "${source_refs}" == "${target_refs}" ]]
}

function import_refs() {
  local tmp_parent
  local mirror_dir
  local target_repo

  target_repo="$(target_repo_url)"
  if refs_are_current "${target_repo}"; then
    echo "Repository refs are already current."
    return 0
  fi

  tmp_parent="$(mktemp -d "${TMP_ROOT}/${PROJECT_NAME}.import.XXXXXX")"
  if [[ -z "${tmp_parent}" || ! -d "${tmp_parent}" ]]; then
    echo "ERROR: Could not create temporary directory under ${TMP_ROOT}."
    exit 1
  fi
  mirror_dir="${tmp_parent}/${PROJECT_NAME}.git"

  function cleanup() {
    if [[ "${KEEP_MIRROR}" != "true" && -d "${tmp_parent}" ]]; then
      rm -rf "${tmp_parent}"
    fi
  }
  trap cleanup EXIT

  echo "Cloning mirror from ${SOURCE_REPO}"
  if ! github_git clone --mirror "${SOURCE_REPO}" "${mirror_dir}"; then
    if [[ -z "${GITHUB_AUTH_HEADER}" ]]; then
      echo "ERROR: Could not read GitHub repository. For a private repository, set GITHUB_TOKEN (or GH_TOKEN) to a token with repository read access, or authenticate with gh." >&2
    fi
    exit 1
  fi

  echo "Pushing branches and tags to ${target_repo}"
  git --git-dir="${mirror_dir}" push "${target_repo}" \
    'refs/heads/*:refs/heads/*' \
    'refs/tags/*:refs/tags/*'
  REFS_CHANGED="true"

  echo "Verifying imported refs"
  git ls-remote "${target_repo}"

  if [[ "${KEEP_MIRROR}" == "true" ]]; then
    echo "Kept temporary mirror at ${mirror_dir}"
  fi
}

while getopts ":r:n:g:v:b:d:kh" opt; do
  case "${opt}" in
    r)
      SOURCE_REPO="${OPTARG}"
      ;;
    n)
      PROJECT_NAME="${OPTARG}"
      ;;
    g)
      GITLAB_GROUP="${OPTARG}"
      ;;
    v)
      GITLAB_VISIBILITY="${OPTARG}"
      ;;
    b)
      DEFAULT_BRANCH="${OPTARG}"
      ;;
    d)
      DESCRIPTION="${OPTARG}"
      ;;
    k)
      KEEP_MIRROR="true"
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
  echo "ERROR: Positional arguments are not supported. Use -r SOURCE."
  usage
fi

if [[ -z "${SOURCE_REPO}" ]]; then
  echo "ERROR: -r SOURCE is required."
  usage
fi

require_command git
require_command glab
require_command jq
verify_glab_auth
validate_visibility
normalize_source "${SOURCE_REPO}"
configure_github_auth

if [[ -z "${DESCRIPTION}" ]]; then
  DESCRIPTION="Mirror of https://github.com/${GITHUB_OWNER}/${PROJECT_NAME}"
fi

detect_default_branch

echo "Source: ${SOURCE_REPO}"
echo "Target: https://${GITLAB_HOST}/${GITLAB_GROUP}/${PROJECT_NAME}"
echo "Visibility: ${GITLAB_VISIBILITY}"
echo "Default branch: ${DEFAULT_BRANCH}"

create_or_update_project
import_refs
update_default_branch

if [[ "${PROJECT_CHANGED}" == "true" || "${REFS_CHANGED}" == "true" || "${DEFAULT_BRANCH_CHANGED}" == "true" ]]; then
  echo "Updated: https://${GITLAB_HOST}/${GITLAB_GROUP}/${PROJECT_NAME}"
else
  echo "Already up to date: https://${GITLAB_HOST}/${GITLAB_GROUP}/${PROJECT_NAME}"
fi
