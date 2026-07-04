#!/bin/bash

# Local wrapper for ../gitlab/scripts/dev_dependencies.sh that keeps generated
# values in this repository instead of writing to the upstream chart checkout.

set -eo pipefail
[[ "${TRACE}" ]] && set -x

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
GITLAB_CHART_ROOT="${GITLAB_CHART_ROOT:-${PROJECT_ROOT}/../gitlab}"
UPSTREAM_SCRIPT_DIR="${GITLAB_CHART_ROOT}/scripts"
VALUES_DIR="${PROJECT_ROOT}/.values"

for helper in helpers.sh valkey.sh cloudnativepg.sh garage.sh; do
  if [[ ! -f "${UPSTREAM_SCRIPT_DIR}/ci/lib/${helper}" ]]; then
    echo "ERROR: Missing upstream helper ${UPSTREAM_SCRIPT_DIR}/ci/lib/${helper}."
    echo "Clone the GitLab chart checkout next to this repo, or set GITLAB_CHART_ROOT."
    exit 1
  fi
done

source "${UPSTREAM_SCRIPT_DIR}/ci/lib/helpers.sh"
source "${UPSTREAM_SCRIPT_DIR}/ci/lib/valkey.sh"
source "${UPSTREAM_SCRIPT_DIR}/ci/lib/cloudnativepg.sh"
source "${UPSTREAM_SCRIPT_DIR}/ci/lib/garage.sh"

function valkey_password() {
  local password

  password="$(openssl rand -hex 16 2>/dev/null || true)"
  if [[ -z "${password}" ]]; then
    password="$(uuidgen 2>/dev/null || true)"
  fi

  if [[ -z "${password}" ]]; then
    echo "ERROR: Failed to generate Valkey password." >&2
    exit 1
  fi

  echo -n "${password}"
}

function valkey_auth_secret_has_password() {
  secret_key_has_value "$(valkey_auth_secret)" "$(valkey_auth_secret_key)"
}

function ensure_valkey_auth_secret_is_usable() {
  if kubectl get secret "$(valkey_auth_secret)" -n "${NAMESPACE}" > /dev/null 2>&1 \
      && ! valkey_auth_secret_has_password; then
    echo "Valkey auth secret '$(valkey_auth_secret)' has an empty password. Recreating it."
    kubectl delete secret -n "${NAMESPACE}" "$(valkey_auth_secret)"
  fi
}

function secret_key_has_value() {
  local secret_name="$1"
  local secret_key="$2"
  local encoded_value

  encoded_value="$(
    kubectl get secret "${secret_name}" \
      -n "${NAMESPACE}" \
      -o "jsonpath={.data.${secret_key}}" 2>/dev/null || true
  )"

  [[ -n "${encoded_value}" ]]
}

function require_secret_key_has_value() {
  local secret_name="$1"
  local secret_key="$2"

  if ! secret_key_has_value "${secret_name}" "${secret_key}"; then
    echo "ERROR: Secret '${secret_name}' is missing key '${secret_key}' or the value is empty."
    return 1
  fi
}

function validate_external_dependencies() {
  local failed=0

  echo "Validating external dependency contract..."

  require_secret_key_has_value "$(valkey_auth_secret)" "$(valkey_auth_secret_key)" || failed=1
  require_secret_key_has_value "$(cnpg_cluster_secret)" password || failed=1
  require_secret_key_has_value "$(garage_release_name)-gitlab-object-storage" config || failed=1
  require_secret_key_has_value "$(garage_release_name)-gitlab-object-storage-s3cmd" config || failed=1
  require_secret_key_has_value "$(garage_release_name)-gitlab-registry-storage" config || failed=1

  if [[ "${failed}" -ne 0 ]]; then
    echo "ERROR: External dependencies are not ready. Run: bash scripts/dev_dependencies.sh setup"
    return 1
  fi

  echo "External dependency contract is valid."
}

function garage_gitlab_storage_secrets_exist() {
  kubectl get secret \
    "$(garage_release_name)-gitlab-object-storage" \
    "$(garage_release_name)-gitlab-object-storage-s3cmd" \
    "$(garage_release_name)-gitlab-registry-storage" \
    -n "${NAMESPACE}" > /dev/null 2>&1
}

function garage_running_pod() {
  kubectl get pod -n "${NAMESPACE}" \
    -l app.kubernetes.io/instance="$(garage_release_name)" \
    --field-selector=status.phase=Running \
    -o jsonpath='{.items[0].metadata.name}'
}

function garage_registry_access_key() {
  kubectl get secret "$(garage_release_name)-gitlab-registry-storage" \
    -n "${NAMESPACE}" \
    -o jsonpath='{.data.config}' 2>/dev/null \
    | base64 -d \
    | awk -F': *' '$1 ~ /^[[:space:]]*accesskey$/ { print $2; exit }'
}

function garage_gitlab_storage_is_usable() {
  local garage_pod access_key key_info

  garage_gitlab_storage_secrets_exist || return 1

  garage_pod="$(garage_running_pod)"
  [[ -n "${garage_pod}" ]] || return 1

  access_key="$(garage_registry_access_key)"
  [[ -n "${access_key}" ]] || return 1

  key_info="$(kubectl exec -n "${NAMESPACE}" "${garage_pod}" -- \
    /garage key info "${access_key}" 2>/dev/null)" || return 1
  grep -q "registry" <<< "${key_info}" || return 1

  kubectl exec -n "${NAMESPACE}" "${garage_pod}" -- \
    /garage bucket info registry > /dev/null 2>&1
}

function delete_garage_gitlab_storage_secrets() {
  kubectl delete secret -n "${NAMESPACE}" \
    "$(garage_release_name)-gitlab-object-storage" \
    "$(garage_release_name)-gitlab-object-storage-s3cmd" \
    "$(garage_release_name)-gitlab-registry-storage" \
    --ignore-not-found
}

function ensure_helm_repo() {
  local repo_name="$1"
  local repo_url="$2"

  if helm repo list -o yaml | grep -qE "^[[:space:]]*- name: ${repo_name}$"; then
    echo "    Updating Helm repo '${repo_name}'..."
    helm repo update "${repo_name}"
  else
    echo "    Adding Helm repo '${repo_name}'..."
    helm repo add "${repo_name}" "${repo_url}"
    helm repo update "${repo_name}"
  fi
}

function deploy_local_valkey() {
  ensure_helm_repo valkey https://valkey.io/valkey-helm/
  ensure_valkey_auth_secret_is_usable
  deploy_external_valkey
  restart_valkey_for_current_secret
}

function restart_valkey_for_current_secret() {
  if ! kubectl "${KUBECTL_CONTEXT_ARGS[@]}" -n "${NAMESPACE}" get deployment "$(valkey_release_name)" > /dev/null 2>&1; then
    return
  fi

  echo "Restarting Valkey so its ACL file matches the current auth secret..."
  kubectl "${KUBECTL_CONTEXT_ARGS[@]}" -n "${NAMESPACE}" rollout restart deployment/"$(valkey_release_name)"
  kubectl "${KUBECTL_CONTEXT_ARGS[@]}" -n "${NAMESPACE}" rollout status deployment/"$(valkey_release_name)" --timeout=180s
}

function install_local_cnpg_operator() {
  ensure_helm_repo cnpg https://cloudnative-pg.github.io/charts
  install_cnpg_operator
}

function deploy_external_garage() {
  if [[ -z "${NAMESPACE}" ]]; then
    echo "Error: NAMESPACE environment variable is not set"
    exit 1
  fi

  if helm status "$(garage_release_name)" -n "${NAMESPACE}" > /dev/null 2>&1; then
    if garage_gitlab_storage_is_usable; then
      echo "Garage already installed and configured. Skipping."
      return
    fi

    if garage_gitlab_storage_secrets_exist; then
      echo "Garage release already exists, but GitLab storage secrets do not match usable Garage state. Reconfiguring."
      delete_garage_gitlab_storage_secrets
    else
      echo "Garage release already exists, but GitLab storage secrets are missing. Reconfiguring."
    fi
  else
    echo "Installing external Garage"

    if ! helm plugin ls | grep -q helm-git; then
      helm plugin install https://github.com/aslafy-z/helm-git
    fi

    GARAGE_APP_VERSION="${GARAGE_APP_VERSION:-2.2.0}"
    ensure_helm_repo garage "git+https://git.deuxfleurs.fr/Deuxfleurs/garage.git@script/helm?ref=v${GARAGE_APP_VERSION}"

    helm upgrade --install "$(garage_release_name)" garage/garage \
      -n "${NAMESPACE}" \
      --set garage.replicationFactor=1 \
      --set deployment.replicaCount=1 \
      --set persistence.enabled=false \
      --set environment[0].name=RUST_LOG \
      --set environment[0].value="garage=warn" \
      --set resources.requests.memory="256Mi" \
      --set resources.requests.cpu="100m" \
      --set resources.limits.memory="512Mi" \
      --set resources.limits.cpu="500m" \
      --set image.repository=docker.io/dxflrs/garage \
      --set initImage.repository=docker.io/busybox \
      $(garage_openshift_values) \
      --wait --timeout=300s
  fi

  GARAGE_POD="$(garage_running_pod)"

  echo "Using Garage pod: ${GARAGE_POD}"

  local NODE_ID
  NODE_ID=$(kubectl exec -n "${NAMESPACE}" "${GARAGE_POD}" -- \
    /garage status 2>/dev/null | grep -oE '[0-9a-f]{16}' | head -1)

  if [[ -z "${NODE_ID}" ]]; then
    echo "ERROR: Could not detect Garage node ID. Full status output:"
    kubectl exec -n "${NAMESPACE}" "${GARAGE_POD}" -- /garage status
    exit 1
  fi
  echo "Detected Garage node ID: ${NODE_ID}"

  kubectl exec -n "${NAMESPACE}" "${GARAGE_POD}" -- /garage layout assign -z ci -c 1G "${NODE_ID}" || true
  kubectl exec -n "${NAMESPACE}" "${GARAGE_POD}" -- /garage layout apply --version 1 || true

  local buckets=(
    "git-lfs"
    "gitlab-agent-plan-content"
    "gitlab-artifacts"
    "gitlab-backups"
    "gitlab-ci-secure-files"
    "gitlab-dependency-proxy"
    "gitlab-mr-diffs"
    "gitlab-packages"
    "gitlab-pages"
    "gitlab-terraform-state"
    "gitlab-uploads"
    "registry"
    "runner-cache"
    "tmp"
  )

  for bucket in "${buckets[@]}"; do
    if kubectl exec -n "${NAMESPACE}" "${GARAGE_POD}" -- /garage bucket create "${bucket}"; then
      echo "Bucket ${bucket} created"
    else
      echo "Bucket ${bucket} might already exist"
    fi
  done

  local KEY_OUTPUT KEY_NAME
  KEY_NAME="gitlab-app-key-$(date +%s)"
  KEY_OUTPUT=$(kubectl exec -n "${NAMESPACE}" "${GARAGE_POD}" -- \
    /garage key create "${KEY_NAME}")

  local GARAGE_ACCESS_KEY GARAGE_SECRET_KEY
  GARAGE_ACCESS_KEY=$(echo "${KEY_OUTPUT}" | grep 'Key ID:' | awk '{print $3}')
  GARAGE_SECRET_KEY=$(echo "${KEY_OUTPUT}" | grep 'Secret key:' | awk '{print $3}')

  if [[ -z "${GARAGE_ACCESS_KEY}" || -z "${GARAGE_SECRET_KEY}" ]]; then
    echo "Error: Failed to extract access key or secret key from garage output"
    exit 1
  fi

  for bucket in "${buckets[@]}"; do
    kubectl exec -n "${NAMESPACE}" "${GARAGE_POD}" -- /garage bucket allow \
      --read --write --key "${KEY_NAME}" "${bucket}"
  done

  kubectl create secret generic "$(garage_release_name)-gitlab-object-storage" \
    --namespace "${NAMESPACE}" \
    --from-literal=config="$(cat <<EOF
provider: AWS
region: garage
aws_access_key_id: ${GARAGE_ACCESS_KEY}
aws_secret_access_key: ${GARAGE_SECRET_KEY}
endpoint: "http://$(garage_release_name).${NAMESPACE}.svc.cluster.local:3900"
path_style: true
EOF
)" --dry-run=client -o yaml | kubectl apply -f -

  kubectl create secret generic "$(garage_release_name)-gitlab-object-storage-s3cmd" \
    --namespace "${NAMESPACE}" \
    --from-literal=config="$(cat <<EOF
[default]
access_key = ${GARAGE_ACCESS_KEY}
secret_key = ${GARAGE_SECRET_KEY}
host_base = $(garage_release_name).${NAMESPACE}.svc.cluster.local:3900
host_bucket = $(garage_release_name).${NAMESPACE}.svc.cluster.local:3900
use_https = False
EOF
)" --dry-run=client -o yaml | kubectl apply -f -

  kubectl create secret generic "$(garage_release_name)-gitlab-registry-storage" \
    --namespace "${NAMESPACE}" \
    --from-literal=config="$(cat <<EOF
s3:
  accesskey: ${GARAGE_ACCESS_KEY}
  secretkey: ${GARAGE_SECRET_KEY}
  bucket: registry
  region: garage
  regionendpoint: http://$(garage_release_name).${NAMESPACE}.svc.cluster.local:3900
  secure: false
  v4auth: true
  pathstyle: true
EOF
)" --dry-run=client -o yaml | kubectl apply -f -

  echo "Garage installation complete"
}

NAMESPACE="${NAMESPACE:-gitlab}"
GARAGE_APP_VERSION="${GARAGE_APP_VERSION:-2.2.0}"
CNPG_POSTGRESQL_TAG="${CNPG_POSTGRESQL_TAG:-17}"
CNPG_CLUSTER_READY_TIMEOUT="${CNPG_CLUSTER_READY_TIMEOUT:-600s}"
K3D_CLUSTER_NAME="${K3D_CLUSTER_NAME:-gitlab-dev}"
KUBE_CONTEXT="${KUBE_CONTEXT:-k3d-${K3D_CLUSTER_NAME}}"
KUBECTL_CONTEXT_ARGS=(--context "${KUBE_CONTEXT}")

GENERATED_VALUES="${VALUES_DIR}/dev-external.values.yaml"

function check_prerequisites() {
  for tool in kubectl helm; do
    if ! command -v "${tool}" > /dev/null 2>&1; then
      echo "ERROR: ${tool} is required but not installed."
      exit 1
    fi
  done
}

function use_kube_context() {
  if ! kubectl config get-contexts "${KUBE_CONTEXT}" > /dev/null 2>&1; then
    echo "ERROR: Kubernetes context '${KUBE_CONTEXT}' was not found."
    echo "Run the Ansible playbook first, or set KUBE_CONTEXT to the context you want to use."
    exit 1
  fi

  kubectl config use-context "${KUBE_CONTEXT}" > /dev/null
}

function namespace_exists() {
  kubectl "${KUBECTL_CONTEXT_ARGS[@]}" get namespace "${NAMESPACE}" > /dev/null 2>&1
}

function ensure_namespace() {
  namespace_exists || kubectl "${KUBECTL_CONTEXT_ARGS[@]}" create namespace "${NAMESPACE}"
  echo "    Namespace: ${NAMESPACE}"
}

function generate_values_file() {
  mkdir -p "${VALUES_DIR}"

  cat > "${GENERATED_VALUES}" <<EOF
# Generated by gitlabc/scripts/dev_dependencies.sh - do not commit this file.
# Use this values file when deploying ../gitlab locally.

global:
  redis:
    host: "$(valkey_release_name)"
    auth:
      secret: "$(valkey_auth_secret)"
      key: "$(valkey_auth_secret_key)"
  psql:
    host: "$(cnpg_cluster_host)"
    password:
      secret: "$(cnpg_cluster_secret)"
      key: password
  appConfig:
    initialDefaults:
      signupEnabled: false
    object_store:
      enabled: true
      proxy_download: true
      connection:
        secret: $(garage_release_name)-gitlab-object-storage
        key: config
    artifacts:
      bucket: gitlab-artifacts
    lfs:
      bucket: git-lfs
    uploads:
      bucket: gitlab-uploads
    packages:
      bucket: gitlab-packages
    externalDiffs:
      enabled: true
      bucket: gitlab-mr-diffs
    terraformState:
      enabled: true
      bucket: gitlab-terraform-state
    ciSecureFiles:
      enabled: true
      bucket: gitlab-ci-secure-files
    agentPlanContent:
      enabled: true
      bucket: gitlab-agent-plan-content
    dependencyProxy:
      enabled: true
      bucket: gitlab-dependency-proxy

gitlab:
  toolbox:
    backups:
      objectStorage:
        config:
          secret: $(garage_release_name)-gitlab-object-storage-s3cmd
          key: config

registry:
  storage:
    secret: $(garage_release_name)-gitlab-registry-storage
    key: config
    redirect:
      disable: true
EOF

  echo "    Generated values file: ${GENERATED_VALUES}"
}

function cmd_setup() {
  echo "Setting up external dependencies in namespace '${NAMESPACE}'..."
  echo ""
  check_prerequisites
  use_kube_context
  ensure_namespace

  echo "==> Setting up Valkey..."
  deploy_local_valkey

  echo "==> Setting up CloudNativePG..."
  install_local_cnpg_operator
  deploy_external_postgresql

  echo "==> Setting up Garage..."
  deploy_external_garage

  generate_values_file
  validate_external_dependencies

  echo ""
  echo "==> All external dependencies are ready."
  echo ""
  echo "Deploy ../gitlab with '-f .values/dev-external.values.yaml'."
}

function cmd_teardown() {
  echo "Removing external dependencies from namespace '${NAMESPACE}'..."
  echo ""
  check_prerequisites
  use_kube_context

  if ! namespace_exists; then
    echo "Namespace '${NAMESPACE}' was not found. Nothing to remove."
    rm -f "${GENERATED_VALUES}"
    return
  fi

  echo "    Removing Valkey..."
  remove_external_valkey
  kubectl delete secret -n "${NAMESPACE}" "$(valkey_auth_secret)" --ignore-not-found
  rm -f "${GENERATED_VALUES}"

  echo "    Removing CloudNativePG cluster..."
  remove_external_postgresql

  echo "    Removing Garage..."
  remove_external_garage
  echo ""
  echo "==> External dependencies removed."
  echo ""
  echo "The namespace '${NAMESPACE}' and GitLab chart release are not affected."
}

function cmd_status() {
  check_prerequisites
  use_kube_context

  echo "External dependency status in namespace '${NAMESPACE}':"
  echo ""

  if ! namespace_exists; then
    echo "Namespace '${NAMESPACE}' was not found."
    return
  fi

  echo "--- Valkey ($(valkey_release_name)) ---"
  kubectl get deployment \
    --namespace "${NAMESPACE}" \
    -l "app.kubernetes.io/instance=$(valkey_release_name)" 2>/dev/null \
    || echo "  Not found"
  if valkey_auth_secret_has_password; then
    echo "  auth secret: present with non-empty $(valkey_auth_secret_key)"
  else
    echo "  auth secret: missing or empty $(valkey_auth_secret_key)"
  fi

  echo ""
  echo "--- CloudNativePG operator ($(cnpg_release_name)) ---"
  kubectl get deployment \
    --namespace "${NAMESPACE}" \
    -l "app.kubernetes.io/instance=$(cnpg_release_name)" 2>/dev/null \
    || echo "  Not found"

  echo ""
  echo "--- PostgreSQL cluster ($(cnpg_cluster_name)) ---"
  kubectl get cluster \
    --namespace "${NAMESPACE}" \
    "$(cnpg_cluster_name)" 2>/dev/null \
    || echo "  Not found"

  echo ""
  echo "--- Garage ---"
  kubectl get statefulset \
    --namespace "${NAMESPACE}" \
    -l app.kubernetes.io/name=garage 2>/dev/null \
    || echo "  Not found"

  echo ""
  echo "--- Object storage secrets ---"
  for secret in \
    "$(garage_release_name)-gitlab-object-storage" \
    "$(garage_release_name)-gitlab-object-storage-s3cmd" \
    "$(garage_release_name)-gitlab-registry-storage"; do
    kubectl get secret --namespace "${NAMESPACE}" "${secret}" \
      -o jsonpath="  {.metadata.name}: present{'\n'}" 2>/dev/null \
      || echo "  ${secret}: not found"
  done
}

function cmd_validate() {
  check_prerequisites
  use_kube_context

  if ! namespace_exists; then
    echo "ERROR: Namespace '${NAMESPACE}' was not found."
    exit 1
  fi

  validate_external_dependencies
}

function usage() {
  cat <<EOF
Usage: $0 {setup|teardown|status|validate}

  setup    Deploy Valkey, CloudNativePG, and Garage as external GitLab dependencies.
  teardown Remove the deployed external dependencies (does not remove the GitLab release).
  status   Show the current status of the external dependencies.
  validate Fail unless all generated dependency secrets exist with non-empty values.

Environment variables:
  NAMESPACE           Kubernetes namespace to use (default: gitlab)
  GARAGE_APP_VERSION  Garage version to install (default: 2.2.0)
  CNPG_POSTGRESQL_TAG PostgreSQL image tag for CloudNativePG (default: 17)
  CNPG_CLUSTER_READY_TIMEOUT
                      Time to wait for the CNPG cluster to become Ready (default: 600s)
  GITLAB_CHART_ROOT   Path to the upstream GitLab chart checkout (default: ../gitlab)
EOF
  exit 1
}

case "${1:-}" in
  setup)    cmd_setup ;;
  teardown) cmd_teardown ;;
  status)   cmd_status ;;
  validate) cmd_validate ;;
  *)        usage ;;
esac
