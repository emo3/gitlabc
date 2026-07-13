#!/bin/bash

# Migrate the local GitLab Container Registry from legacy object-storage
# metadata to the PostgreSQL metadata database. This is a one-step import and
# places the registry in read-only mode while the import is running.

set -euo pipefail
[[ "${TRACE:-}" ]] && set -x

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

NAMESPACE="${NAMESPACE:-gitlab}"
RELEASE_NAME="${RELEASE_NAME:-gitlab}"
K3D_CLUSTER_NAME="${K3D_CLUSTER_NAME:-gitlab-dev}"
KUBE_CONTEXT="${KUBE_CONTEXT:-k3d-${K3D_CLUSTER_NAME}}"
VALUES_FILE="${VALUES_FILE:-${PROJECT_ROOT}/.values/dev-external.values.yaml}"
REGISTRY_DATABASE_PASSWORD_SECRET="${REGISTRY_DATABASE_PASSWORD_SECRET:-dev-cluster-registry-app}"
CONFIRM="${REGISTRY_METADATA_MIGRATION_CONFIRM:-false}"

function usage() {
  cat <<'EOF'
Usage:
  REGISTRY_METADATA_MIGRATION_CONFIRM=true bash scripts/migrate_registry_metadata_database.sh

The registry is made read-only while existing image metadata is imported into
PostgreSQL. Do not push or delete registry images until the command finishes.
EOF
}

function registry_pod() {
  kubectl --context "${KUBE_CONTEXT}" -n "${NAMESPACE}" get pods \
    -l "app=registry,release=${RELEASE_NAME}" \
    --field-selector=status.phase=Running \
    -o jsonpath='{.items[0].metadata.name}'
}

function wait_for_registry() {
  kubectl --context "${KUBE_CONTEXT}" -n "${NAMESPACE}" rollout status \
    deployment/"${RELEASE_NAME}-registry" --timeout=10m
}

function wait_for_migrations() {
  local job

  for _ in $(seq 1 60); do
    job="$(kubectl --context "${KUBE_CONTEXT}" -n "${NAMESPACE}" get jobs \
      -l "app=registry-migrations,release=${RELEASE_NAME}" \
      --sort-by=.metadata.creationTimestamp \
      -o jsonpath='{.items[-1:].metadata.name}' 2>/dev/null || true)"
    [[ -n "${job}" ]] && break
    sleep 2
  done

  if [[ -z "${job:-}" ]]; then
    echo "ERROR: Registry migration job was not created." >&2
    exit 1
  fi

  kubectl --context "${KUBE_CONTEXT}" -n "${NAMESPACE}" wait \
    --for=condition=complete "job/${job}" --timeout=10m
}

if [[ "${CONFIRM}" != "true" ]]; then
  usage >&2
  exit 2
fi

if [[ ! -f "${VALUES_FILE}" ]]; then
  echo "ERROR: Values file not found: ${VALUES_FILE}" >&2
  echo "Run: bash scripts/dev_dependencies.sh setup" >&2
  exit 1
fi

if ! kubectl config get-contexts "${KUBE_CONTEXT}" >/dev/null 2>&1; then
  echo "ERROR: Kubernetes context '${KUBE_CONTEXT}' was not found." >&2
  exit 1
fi

current_database_enabled="$(kubectl --context "${KUBE_CONTEXT}" -n "${NAMESPACE}" get configmap "${RELEASE_NAME}-registry" \
  -o jsonpath='{.data.config\.yml\.tpl}' 2>/dev/null \
  | awk '/^database:/{in_database=1; next} in_database && /^  enabled:/{print $2; exit}')"
if [[ "${current_database_enabled}" == "true" ]]; then
  echo "Registry metadata database is already enabled; no migration is needed."
  exit 0
fi

if ! kubectl --context "${KUBE_CONTEXT}" -n "${NAMESPACE}" get secret \
  "${REGISTRY_DATABASE_PASSWORD_SECRET}" >/dev/null 2>&1; then
  echo "ERROR: Registry database credentials are missing." >&2
  echo "Run: bash scripts/dev_dependencies.sh setup" >&2
  exit 1
fi

readonly_values="$(mktemp)"
trap 'rm -f "${readonly_values}"' EXIT

cat > "${readonly_values}" <<'EOF'
registry:
  maintenance:
    readonly:
      enabled: true
  database:
    configure: true
    enabled: false
    migrations:
      enabled: true
EOF

echo "Preparing the registry metadata database and enabling read-only mode..."
EXTRA_VALUES_FILE="${readonly_values}" \
  VALUES_FILE="${VALUES_FILE}" \
  SETUP_DEPENDENCIES=false \
  RESTART_GITLAB_WORKLOADS=false \
  CONFIGURE_K3D_REGISTRY_PULLS=false \
  DISABLE_PUBLIC_SIGNUPS=false \
  CONFIGURE_GLAB_OAUTH=false \
  bash "${SCRIPT_DIR}/deploy_gitlab.sh"
wait_for_registry
wait_for_migrations

pod="$(registry_pod)"
if [[ -z "${pod}" ]]; then
  echo "ERROR: No running registry pod was found." >&2
  exit 1
fi

echo "Importing existing registry metadata from object storage..."
kubectl --context "${KUBE_CONTEXT}" -n "${NAMESPACE}" exec "${pod}" -c registry -- \
  env REGISTRY_CONFIGURATION_PATH=/etc/docker/registry/config.yml REGISTRY_DATABASE_ENABLED=true \
  /usr/bin/registry database import --log-to-stdout

echo "Enabling metadata-database mode and restoring registry writes..."
VALUES_FILE="${VALUES_FILE}" \
  SETUP_DEPENDENCIES=false \
  RESTART_GITLAB_WORKLOADS=false \
  CONFIGURE_K3D_REGISTRY_PULLS=false \
  DISABLE_PUBLIC_SIGNUPS=false \
  CONFIGURE_GLAB_OAUTH=false \
  bash "${SCRIPT_DIR}/deploy_gitlab.sh"
wait_for_registry
wait_for_migrations

enabled="$(kubectl --context "${KUBE_CONTEXT}" -n "${NAMESPACE}" get configmap "${RELEASE_NAME}-registry" \
  -o jsonpath='{.data.config\.yml\.tpl}' | awk '/^database:/{in_database=1; next} in_database && /^  enabled:/{print $2; exit}')"
if [[ "${enabled}" != "true" ]]; then
  echo "ERROR: Registry metadata database was not enabled after the migration." >&2
  exit 1
fi

echo "Registry metadata-database migration completed. Refresh the Container Registry page to view tags."
