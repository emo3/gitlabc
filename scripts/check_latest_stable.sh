#!/bin/bash

# Check local version pins against the latest stable upstream releases.

set -eo pipefail
[[ "${TRACE}" ]] && set -x

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ANSIBLE_PLAYBOOK="${ANSIBLE_PLAYBOOK:-${PROJECT_ROOT}/ansible-install-k8s-tools-gitlab-deps.yml}"
DEPLOY_SCRIPT="${DEPLOY_SCRIPT:-${PROJECT_ROOT}/scripts/deploy_gitlab.sh}"

STRICT=false
RUN_HEALTH=false
UPDATE_HELM_REPOS=false

function usage() {
  cat <<'USAGE'
Usage: bash scripts/check_latest_stable.sh [-s] [-H] [-r]

Checks local version pins against current stable upstream releases.

Options:
  -s  Exit non-zero when a local pin is not latest stable.
  -H  Run scripts/check_status.sh after the version check.
  -r  Refresh local Helm repository indexes before checking chart versions.
  -h  Show this help.

Daily audit example:
  bash scripts/check_latest_stable.sh -s -H -r
USAGE
}

while getopts ":sHrh" opt; do
  case "${opt}" in
    s)
      STRICT=true
      ;;
    H)
      RUN_HEALTH=true
      ;;
    r)
      UPDATE_HELM_REPOS=true
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

function require_command() {
  local name="$1"

  if ! command -v "${name}" >/dev/null 2>&1; then
    echo "ERROR: ${name} is required but not installed."
    exit 1
  fi
}

function yaml_var() {
  local name="$1"

  sed -nE "s/^[[:space:]]+${name}: \"([^\"]+)\"$/\1/p" "${ANSIBLE_PLAYBOOK}" | head -1
}

function shell_default_var() {
  local name="$1"
  local file="$2"

  sed -nE "s/^${name}=\"\\\$\\{${name}:-([^}]+)\\}\"$/\1/p" "${file}" | head -1
}

function github_latest_tag() {
  local repo="$1"

  curl -fsSL "https://api.github.com/repos/${repo}/releases/latest" \
    | sed -nE 's/^[[:space:]]*"tag_name": "([^"]+)".*/\1/p' \
    | head -1
}

function gitlab_latest_tag() {
  curl -fsSL "https://gitlab.com/api/v4/projects/gitlab-org%2Fcli/releases/permalink/latest" \
    | sed -nE 's/.*"tag_name":"([^"]+)".*/\1/p' \
    | head -1
}

function ensure_helm_repo() {
  local name="$1"
  local url="$2"

  if helm repo list | awk '{print $1}' | grep -qx "${name}"; then
    return 0
  fi

  helm repo add "${name}" "${url}" >/dev/null
}

function latest_chart() {
  local chart="$1"

  { helm search repo "${chart}" --versions 2>/dev/null || true; } | awk 'NR == 2 { print $2 }'
}

function latest_chart_app() {
  local chart="$1"

  { helm search repo "${chart}" --versions 2>/dev/null || true; } | awk 'NR == 2 { print $3 }'
}

function chart_app_version() {
  local chart="$1"
  local chart_version="$2"

  { helm search repo "${chart}" --versions 2>/dev/null || true; } \
    | awk -v chart_version="${chart_version}" 'NR > 1 && $2 == chart_version { print $3; exit }'
}

function strip_v() {
  sed -E 's/^\s*v?//'
}

function installed_kubectl_version() {
  command -v kubectl >/dev/null 2>&1 || return 0
  kubectl version --client --output=yaml 2>/dev/null | awk '/gitVersion:/ { print $2; exit }'
}

function installed_helm_version() {
  command -v helm >/dev/null 2>&1 || return 0
  helm version --short 2>/dev/null | sed -nE 's/^(v[0-9.]+).*/\1/p'
}

function installed_glab_version() {
  command -v glab >/dev/null 2>&1 || return 0
  glab version 2>/dev/null | awk 'NR == 1 { print $2; exit }'
}

function installed_k3d_version() {
  command -v k3d >/dev/null 2>&1 || return 0
  k3d version 2>/dev/null | awk '$1 == "k3d" && $2 == "version" { print $3; exit }'
}

function installed_k3d_default_k3s_version() {
  command -v k3d >/dev/null 2>&1 || return 0
  k3d version 2>/dev/null | awk '$1 == "k3s" && $2 == "version" { print $3; exit }'
}

function installed_mkcert_version() {
  command -v mkcert >/dev/null 2>&1 || return 0
  mkcert --version 2>/dev/null
}

function add_result() {
  local name="$1"
  local current="$2"
  local latest="$3"
  local note="${4:-}"
  local status="OK"

  if [[ -z "${latest}" ]]; then
    status="UNKNOWN"
  elif [[ "$(strip_v <<< "${current}")" != "$(strip_v <<< "${latest}")" ]]; then
    status="DRIFT"
    DRIFT_COUNT=$((DRIFT_COUNT + 1))
  fi

  printf '%-24s %-24s %-24s %-8s %s\n' "${name}" "${current:-unknown}" "${latest:-unknown}" "${status}" "${note}"
}

require_command curl
require_command helm

if [[ ! -f "${ANSIBLE_PLAYBOOK}" ]]; then
  echo "ERROR: Ansible playbook not found at ${ANSIBLE_PLAYBOOK}."
  exit 1
fi

if [[ ! -f "${DEPLOY_SCRIPT}" ]]; then
  echo "ERROR: Deploy script not found at ${DEPLOY_SCRIPT}."
  exit 1
fi

if [[ "${UPDATE_HELM_REPOS}" == "true" ]]; then
  ensure_helm_repo gitlab https://charts.gitlab.io/
  ensure_helm_repo valkey https://valkey.io/valkey-helm/
  ensure_helm_repo cnpg https://cloudnative-pg.github.io/charts
  helm repo update gitlab valkey cnpg >/dev/null
fi

DRIFT_COUNT=0

KUBECTL_CURRENT="$(yaml_var kubectl_version)"
HELM_CURRENT="$(yaml_var helm_version)"
GLAB_CURRENT="$(yaml_var glab_version)"
K3D_CURRENT="$(yaml_var k3d_version)"
K3S_IMAGE_CURRENT="$(yaml_var k3s_image)"
if [[ -n "${K3S_IMAGE_CURRENT}" ]]; then
  K3S_CURRENT="${K3S_IMAGE_CURRENT##*:}"
  K3S_CURRENT="${K3S_CURRENT/-k3s/+k3s}"
else
  K3S_DEFAULT="$(installed_k3d_default_k3s_version)"
  K3S_CURRENT="${K3S_DEFAULT:-k3d default}"
fi
MKCERT_CURRENT="$(yaml_var mkcert_version)"
GITLAB_CHART_CURRENT="$(shell_default_var GITLAB_CHART_VERSION "${DEPLOY_SCRIPT}")"
GARAGE_CURRENT="$(sed -nE 's/^GARAGE_APP_VERSION="\$\{GARAGE_APP_VERSION:-([^}]+)\}"$/\1/p' "${PROJECT_ROOT}/scripts/dev_dependencies.sh" | head -1)"
POSTGRES_CURRENT="$(sed -nE 's/^CNPG_POSTGRESQL_TAG="\$\{CNPG_POSTGRESQL_TAG:-([^}]+)\}"$/\1/p' "${PROJECT_ROOT}/scripts/dev_dependencies.sh" | head -1)"

KUBECTL_LATEST="$(curl -fsSL https://dl.k8s.io/release/stable.txt)"
HELM_LATEST="$(github_latest_tag helm/helm)"
GLAB_LATEST="$(gitlab_latest_tag)"
K3D_LATEST="$(github_latest_tag k3d-io/k3d)"
K3S_LATEST="$(github_latest_tag k3s-io/k3s)"
MKCERT_LATEST="$(github_latest_tag FiloSottile/mkcert)"
GITLAB_CHART_LATEST="$(latest_chart gitlab/gitlab)"
GITLAB_APP_LATEST="$(latest_chart_app gitlab/gitlab)"
VALKEY_CHART_LATEST="$(latest_chart valkey/valkey)"
VALKEY_APP_LATEST="$(latest_chart_app valkey/valkey)"
CNPG_CHART_LATEST="$(latest_chart cnpg/cloudnative-pg)"
CNPG_APP_LATEST="$(latest_chart_app cnpg/cloudnative-pg)"
VALKEY_CHART_CURRENT="${VALKEY_CHART_VERSION:-${VALKEY_CHART_LATEST}}"
CNPG_CHART_CURRENT="${CNPG_CHART_VERSION:-${CNPG_CHART_LATEST}}"
VALKEY_APP_CURRENT="$(chart_app_version valkey/valkey "${VALKEY_CHART_CURRENT}")"
CNPG_APP_CURRENT="$(chart_app_version cnpg/cloudnative-pg "${CNPG_CHART_CURRENT}")"

printf '%-24s %-24s %-24s %-8s %s\n' "Component" "Current" "Latest stable" "Status" "Note"
printf '%-24s %-24s %-24s %-8s %s\n' "---------" "-------" "-------------" "------" "----"
add_result kubectl "${KUBECTL_CURRENT}" "${KUBECTL_LATEST}" "keep within one minor of K3s"
add_result Helm "${HELM_CURRENT}" "${HELM_LATEST}"
add_result glab "${GLAB_CURRENT}" "${GLAB_LATEST}"
add_result k3d "${K3D_CURRENT}" "${K3D_LATEST}"
if [[ -n "${K3S_IMAGE_CURRENT}" ]]; then
  add_result K3s "${K3S_CURRENT}" "${K3S_LATEST}" "cluster rebuild required to change"
else
  printf '%-24s %-24s %-24s %-8s %s\n' "K3s" "${K3S_CURRENT}" "${K3S_LATEST}" "INFO" "k3d default; set k3s_image only after scanner review"
fi
add_result mkcert "${MKCERT_CURRENT}" "${MKCERT_LATEST}"
add_result "GitLab chart" "${GITLAB_CHART_CURRENT}" "${GITLAB_CHART_LATEST}" "app ${GITLAB_APP_LATEST}"
add_result "Valkey chart" "${VALKEY_CHART_CURRENT}" "${VALKEY_CHART_LATEST}" "set VALKEY_CHART_VERSION to audit an explicit pin"
add_result "Valkey app" "${VALKEY_APP_CURRENT}" "${VALKEY_APP_LATEST}" "from selected Valkey chart"
add_result "CNPG chart" "${CNPG_CHART_CURRENT}" "${CNPG_CHART_LATEST}" "set CNPG_CHART_VERSION to audit an explicit pin"
add_result "CNPG app" "${CNPG_APP_CURRENT}" "${CNPG_APP_LATEST}" "from selected CNPG chart"
add_result Garage "${GARAGE_CURRENT}" "${GARAGE_CURRENT}" "pinned by app release"
add_result PostgreSQL "${POSTGRES_CURRENT}" "${POSTGRES_CURRENT}" "do not auto-bump without GitLab support check"

echo ""
printf '%-24s %-24s %-24s %-8s %s\n' "Installed binary" "Installed" "Pinned" "Status" "Note"
printf '%-24s %-24s %-24s %-8s %s\n' "----------------" "---------" "------" "------" "----"
add_result kubectl "$(installed_kubectl_version)" "${KUBECTL_CURRENT}"
add_result Helm "$(installed_helm_version)" "${HELM_CURRENT}"
add_result glab "$(installed_glab_version)" "${GLAB_CURRENT}"
add_result k3d "$(installed_k3d_version)" "v${K3D_CURRENT}" "stale k3d creates stale k3d-tools/proxy images"
add_result mkcert "$(installed_mkcert_version)" "${MKCERT_CURRENT}"

if [[ "${RUN_HEALTH}" == "true" ]]; then
  echo ""
  bash "${PROJECT_ROOT}/scripts/check_status.sh"
fi

if [[ "${STRICT}" == "true" && "${DRIFT_COUNT}" -ne 0 ]]; then
  echo ""
  echo "ERROR: ${DRIFT_COUNT} pinned component(s) are not on latest stable."
  exit 2
fi
