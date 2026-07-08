#!/bin/bash

# Deploy a stable GitLab chart release from the official Helm repository.

set -eo pipefail
[[ "${TRACE}" ]] && set -x

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CODE_ROOT="$(cd "${PROJECT_ROOT}/.." && pwd)"

NAMESPACE="${NAMESPACE:-gitlab}"
RELEASE_NAME="${RELEASE_NAME:-gitlab}"
GITLAB_DEPLOY_PROFILE="${GITLAB_DEPLOY_PROFILE:-local-mkcert}"
GITLAB_DOMAIN="${GITLAB_DOMAIN:-127.0.0.1.nip.io}"
GITLAB_EXTERNAL_IP="${GITLAB_EXTERNAL_IP:-127.0.0.1}"
GITLAB_TLS_SECRET="${GITLAB_TLS_SECRET:-}"
CERTMANAGER_EMAIL="${CERTMANAGER_EMAIL:-infuse.1301@gmail.com}"
DEFAULT_VALUES_FILE="${PROJECT_ROOT}/.values/dev-external.values.yaml"
PUBLIC_LETSENCRYPT_VALUES_FILE="${PROJECT_ROOT}/public-letsencrypt.values.yaml"
SETUP_DEPENDENCIES="${SETUP_DEPENDENCIES:-true}"
VALIDATE_DEPENDENCIES="${VALIDATE_DEPENDENCIES:-true}"
SETUP_LOCAL_TLS="${SETUP_LOCAL_TLS:-true}"
RESTART_GITLAB_WORKLOADS="${RESTART_GITLAB_WORKLOADS:-true}"
DISABLE_PUBLIC_SIGNUPS="${DISABLE_PUBLIC_SIGNUPS:-true}"
CONFIGURE_GLAB_OAUTH="${CONFIGURE_GLAB_OAUTH:-true}"
CONFIGURE_K3D_REGISTRY_PULLS="${CONFIGURE_K3D_REGISTRY_PULLS:-true}"
GLAB_OAUTH_APP_NAME="${GLAB_OAUTH_APP_NAME:-glab-cli}"
GLAB_OAUTH_REDIRECT_URI="${GLAB_OAUTH_REDIRECT_URI:-http://localhost:7171/auth/redirect}"
GLAB_OAUTH_SCOPES="${GLAB_OAUTH_SCOPES:-openid profile read_user write_repository api}"
PUBLIC_WEB_IDE_EXTENSION_HOST_DOMAIN="${PUBLIC_WEB_IDE_EXTENSION_HOST_DOMAIN:-cdn.web-ide.gitlab-static.net}"
PUBLIC_WEB_IDE_SINGLE_ORIGIN_FALLBACK_ENABLED="${PUBLIC_WEB_IDE_SINGLE_ORIGIN_FALLBACK_ENABLED:-false}"
GITLAB_HELM_REPO_NAME="${GITLAB_HELM_REPO_NAME:-gitlab}"
GITLAB_HELM_REPO_URL="${GITLAB_HELM_REPO_URL:-https://charts.gitlab.io/}"
GITLAB_CHART_REF="${GITLAB_CHART_REF:-${GITLAB_HELM_REPO_NAME}/gitlab}"
GITLAB_CHART_VERSION="${GITLAB_CHART_VERSION:-10.1.1}"
K3D_CLUSTER_NAME="${K3D_CLUSTER_NAME:-gitlab-dev}"
KUBE_CONTEXT="${KUBE_CONTEXT:-k3d-${K3D_CLUSTER_NAME}}"
XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-${CODE_ROOT}/.glab-config}"

cd "${PROJECT_ROOT}"

VALUES_FILES=()
PROFILE_SET_ARGS=()
TLS_SECRET_ARGS=()

function add_values_file() {
  local values_file="$1"

  if [[ ! -f "${values_file}" ]]; then
    echo "ERROR: Values file not found at ${values_file}."
    if [[ "${values_file}" == "${DEFAULT_VALUES_FILE}" ]]; then
      echo "Run: bash scripts/dev_dependencies.sh setup"
    fi
    exit 1
  fi

  VALUES_FILES+=(-f "${values_file}")
}

function disable_public_signups() {
  local toolbox_pod

  toolbox_pod="$(
    kubectl --context "${KUBE_CONTEXT}" -n "${NAMESPACE}" get pod \
      -l "release=${RELEASE_NAME},app=toolbox" \
      --field-selector=status.phase=Running \
      -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true
  )"

  if [[ -z "${toolbox_pod}" ]]; then
    echo "WARNING: Toolbox pod is not running yet; could not apply existing-instance signup setting."
    echo "         Run this after GitLab is healthy: DISABLE_PUBLIC_SIGNUPS=true bash scripts/deploy_gitlab.sh"
    return 0
  fi

  echo "Disabling public sign-ups in GitLab application settings..."
  kubectl --context "${KUBE_CONTEXT}" -n "${NAMESPACE}" exec "${toolbox_pod}" -c toolbox -- \
    gitlab-rails runner 'ApplicationSetting.current.update!(signup_enabled: false); puts "signup_enabled=#{ApplicationSetting.current.signup_enabled}"'
}

function validate_boolean() {
  local name="$1"
  local value="$2"

  case "${value}" in
    true|false)
      ;;
    *)
      echo "ERROR: ${name} must be 'true' or 'false'."
      exit 1
      ;;
  esac
}

function running_toolbox_pod() {
  kubectl --context "${KUBE_CONTEXT}" -n "${NAMESPACE}" get pod \
    -l "release=${RELEASE_NAME},app=toolbox" \
    --field-selector=status.phase=Running \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true
}

function configure_web_ide_extension_host() {
  local toolbox_pod

  validate_boolean PUBLIC_WEB_IDE_SINGLE_ORIGIN_FALLBACK_ENABLED "${PUBLIC_WEB_IDE_SINGLE_ORIGIN_FALLBACK_ENABLED}"

  toolbox_pod="$(running_toolbox_pod)"
  if [[ -z "${toolbox_pod}" ]]; then
    echo "WARNING: Toolbox pod is not running yet; could not configure Web IDE extension host settings."
    echo "         Run this after GitLab is healthy: bash scripts/deploy_gitlab.sh"
    return 0
  fi

  echo "Configuring Web IDE extension host settings..."
  kubectl --context "${KUBE_CONTEXT}" -n "${NAMESPACE}" exec "${toolbox_pod}" -c toolbox -- \
    env \
      PUBLIC_WEB_IDE_EXTENSION_HOST_DOMAIN="${PUBLIC_WEB_IDE_EXTENSION_HOST_DOMAIN}" \
      PUBLIC_WEB_IDE_SINGLE_ORIGIN_FALLBACK_ENABLED="${PUBLIC_WEB_IDE_SINGLE_ORIGIN_FALLBACK_ENABLED}" \
      gitlab-rails runner '
domain = ENV.fetch("PUBLIC_WEB_IDE_EXTENSION_HOST_DOMAIN")
fallback_enabled = ENV.fetch("PUBLIC_WEB_IDE_SINGLE_ORIGIN_FALLBACK_ENABLED") == "true"

ApplicationSetting.current.update!(
  vscode_extension_marketplace_extension_host_domain: domain,
  vscode_extension_marketplace_single_origin_fallback_enabled: fallback_enabled
)

settings = ApplicationSetting.current
puts "vscode_extension_marketplace_extension_host_domain=#{settings.vscode_extension_marketplace_extension_host_domain}"
puts "vscode_extension_marketplace_single_origin_fallback_enabled=#{settings.vscode_extension_marketplace_single_origin_fallback_enabled}"
'
}

function configure_glab_oauth() {
  local toolbox_pod
  local gitlab_host
  local client_id

  validate_boolean CONFIGURE_GLAB_OAUTH "${CONFIGURE_GLAB_OAUTH}"
  if [[ "${CONFIGURE_GLAB_OAUTH}" != "true" ]]; then
    return 0
  fi

  if ! command -v glab >/dev/null 2>&1; then
    echo "WARNING: glab is not installed; could not configure browser OAuth client_id."
    echo "         Run the Ansible playbook first, or set CONFIGURE_GLAB_OAUTH=false."
    return 0
  fi

  toolbox_pod="$(running_toolbox_pod)"
  if [[ -z "${toolbox_pod}" ]]; then
    echo "WARNING: Toolbox pod is not running yet; could not configure glab browser OAuth."
    echo "         Run this after GitLab is healthy: CONFIGURE_GLAB_OAUTH=true bash scripts/deploy_gitlab.sh"
    return 0
  fi

  gitlab_host="gitlab.${GITLAB_DOMAIN}"

  echo "Configuring glab browser OAuth application..."
  client_id="$(
    kubectl --context "${KUBE_CONTEXT}" -n "${NAMESPACE}" exec "${toolbox_pod}" -c toolbox -- \
      env \
        GLAB_OAUTH_APP_NAME="${GLAB_OAUTH_APP_NAME}" \
        GLAB_OAUTH_REDIRECT_URI="${GLAB_OAUTH_REDIRECT_URI}" \
        GLAB_OAUTH_SCOPES="${GLAB_OAUTH_SCOPES}" \
        gitlab-rails runner '
name = ENV.fetch("GLAB_OAUTH_APP_NAME")
redirect_uri = ENV.fetch("GLAB_OAUTH_REDIRECT_URI")
scopes = ENV.fetch("GLAB_OAUTH_SCOPES")

app = Doorkeeper::Application.find_or_initialize_by(name: name)
organization = Organizations::Organization.default_organization

app.redirect_uri = redirect_uri
app.scopes = scopes
app.organization_id = organization.id if app.respond_to?(:organization_id=)
app.confidential = false if app.respond_to?(:confidential=)
app.save!

puts app.uid
'
  )"

  if [[ -z "${client_id}" ]]; then
    echo "WARNING: GitLab did not return a glab OAuth client_id."
    return 0
  fi

  XDG_CONFIG_HOME="${XDG_CONFIG_HOME}" glab config set client_id "${client_id}" --host "${gitlab_host}"
  echo "Configured glab OAuth client_id for ${gitlab_host}."
}

if ! kubectl config get-contexts "${KUBE_CONTEXT}" > /dev/null 2>&1; then
  echo "ERROR: Kubernetes context '${KUBE_CONTEXT}' was not found."
  echo "Run the Ansible playbook first, or set KUBE_CONTEXT to the context you want to deploy to."
  exit 1
fi

if [[ "${SETUP_DEPENDENCIES}" == "true" ]]; then
  NAMESPACE="${NAMESPACE}" KUBE_CONTEXT="${KUBE_CONTEXT}" \
    bash scripts/dev_dependencies.sh setup
fi

if [[ "${VALIDATE_DEPENDENCIES}" == "true" ]]; then
  NAMESPACE="${NAMESPACE}" KUBE_CONTEXT="${KUBE_CONTEXT}" \
    bash scripts/dev_dependencies.sh validate
fi

case "${GITLAB_DEPLOY_PROFILE}" in
  local|local-mkcert)
    add_values_file "${VALUES_FILE:-${DEFAULT_VALUES_FILE}}"
    GITLAB_TLS_SECRET="${GITLAB_TLS_SECRET:-gitlab-local-tls}"

    if [[ "${SETUP_LOCAL_TLS}" == "true" ]]; then
      NAMESPACE="${NAMESPACE}" KUBE_CONTEXT="${KUBE_CONTEXT}" GITLAB_DOMAIN="${GITLAB_DOMAIN}" GITLAB_TLS_SECRET="${GITLAB_TLS_SECRET}" \
        bash scripts/create_mkcert.sh
    fi

    if ! kubectl --context "${KUBE_CONTEXT}" -n "${NAMESPACE}" get secret "${GITLAB_TLS_SECRET}" > /dev/null 2>&1; then
      echo "ERROR: TLS secret '${GITLAB_TLS_SECRET}' was not found in namespace '${NAMESPACE}'."
      echo "Run: bash scripts/create_mkcert.sh"
      exit 1
    fi
    TLS_SECRET_ARGS+=(--set "global.ingress.tls.secretName=${GITLAB_TLS_SECRET}")

    PROFILE_SET_ARGS=(
      --set "global.hosts.domain=${GITLAB_DOMAIN}"
      --set "global.hosts.externalIP=${GITLAB_EXTERNAL_IP}"
      --set "certmanager-issuer.email=${CERTMANAGER_EMAIL}"
      --set "global.hosts.https=true"
      --set "global.ingress.enabled=true"
      --set "global.ingress.configureCertmanager=false"
      --set "global.ingress.tls.enabled=true"
      "${TLS_SECRET_ARGS[@]}"
      --set "nginx-ingress.enabled=true"
      --set-string "global.ingress.annotations.nginx\\.ingress\\.kubernetes\\.io/ssl-redirect=true"
      --set-string "global.ingress.annotations.nginx\\.ingress\\.kubernetes\\.io/force-ssl-redirect=true"
    )
    GITLAB_URL="https://gitlab.${GITLAB_DOMAIN}/users/sign_in"
    ;;
  public-letsencrypt)
    add_values_file "${VALUES_FILE:-${DEFAULT_VALUES_FILE}}"
    add_values_file "${PUBLIC_LETSENCRYPT_VALUES_FILE}"
    PROFILE_SET_ARGS=(
      --set-string "global.ingress.annotations.nginx\\.ingress\\.kubernetes\\.io/ssl-redirect=true"
      --set-string "global.ingress.annotations.nginx\\.ingress\\.kubernetes\\.io/force-ssl-redirect=true"
    )
    GITLAB_URL="https://gitlab.edmo3.dynv6.net/users/sign_in"
    ;;
  *)
    echo "ERROR: Unknown GITLAB_DEPLOY_PROFILE '${GITLAB_DEPLOY_PROFILE}'."
    echo "Supported profiles: local-mkcert, public-letsencrypt"
    exit 1
    ;;
esac

if ! helm repo list | awk '{print $1}' | grep -qx "${GITLAB_HELM_REPO_NAME}"; then
  echo "Adding Helm repo '${GITLAB_HELM_REPO_NAME}'..."
  helm repo add "${GITLAB_HELM_REPO_NAME}" "${GITLAB_HELM_REPO_URL}"
fi

echo "Updating Helm repo '${GITLAB_HELM_REPO_NAME}'..."
helm repo update "${GITLAB_HELM_REPO_NAME}"

echo "Deploying GitLab release '${RELEASE_NAME}' to namespace '${NAMESPACE}'..."
helm upgrade --install "${RELEASE_NAME}" "${GITLAB_CHART_REF}" \
  --kube-context "${KUBE_CONTEXT}" \
  --namespace "${NAMESPACE}" \
  --version "${GITLAB_CHART_VERSION}" \
  --timeout 600s \
  --force-conflicts \
  "${VALUES_FILES[@]}" \
  "${PROFILE_SET_ARGS[@]}" \
  --set "global.gatewayApi.enabled=false" \
  --set "global.gatewayApi.installEnvoy=false" \
  --set "global.gatewayApi.configureCertmanager=false" \
  --set "gatewayApiResources.enabled=false" \
  --set "certmanager.config.enableGatewayAPI=false" \
  --set "gitlab-runner.install=false" \
  --set "prometheus.install=false"

if [[ "${RESTART_GITLAB_WORKLOADS}" == "true" ]]; then
  echo "Restarting GitLab workloads that consume external dependency secrets..."
  kubectl --context "${KUBE_CONTEXT}" -n "${NAMESPACE}" rollout restart deployment \
    -l "release=${RELEASE_NAME},app in (webservice,sidekiq,kas,gitlab-exporter)"
fi

if [[ "${CONFIGURE_K3D_REGISTRY_PULLS}" == "true" && "${GITLAB_DEPLOY_PROFILE}" != "public-letsencrypt" ]]; then
  echo "Configuring k3d nodes for local GitLab registry pulls..."
  NAMESPACE="${NAMESPACE}" KUBE_CONTEXT="${KUBE_CONTEXT}" K3D_CLUSTER_NAME="${K3D_CLUSTER_NAME}" GITLAB_DOMAIN="${GITLAB_DOMAIN}" \
    bash scripts/configure_k3d_registry_pull.sh
fi

if [[ "${DISABLE_PUBLIC_SIGNUPS}" == "true" ]]; then
  disable_public_signups
fi

configure_web_ide_extension_host
configure_glab_oauth

echo "GitLab deploy submitted."
echo "Open: ${GITLAB_URL}"
if [[ "${GITLAB_DEPLOY_PROFILE}" == "local" || "${GITLAB_DEPLOY_PROFILE}" == "local-mkcert" ]]; then
  echo "TLS uses mkcert Kubernetes secret '${GITLAB_TLS_SECRET}'."
elif [[ "${GITLAB_DEPLOY_PROFILE}" == "public-letsencrypt" ]]; then
  echo "TLS is managed by cert-manager and Let's Encrypt."
fi
