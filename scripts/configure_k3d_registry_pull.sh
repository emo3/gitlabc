#!/bin/bash

# Configure k3d node containers so containerd can pull from the local GitLab
# registry using the same external hostnames used by GitLab and CI.

set -eo pipefail
[[ "${TRACE}" ]] && set -x

K3D_CLUSTER_NAME="${K3D_CLUSTER_NAME:-gitlab-dev}"
KUBE_CONTEXT="${KUBE_CONTEXT:-k3d-${K3D_CLUSTER_NAME}}"
NAMESPACE="${NAMESPACE:-gitlab}"
GITLAB_DOMAIN="${GITLAB_DOMAIN:-127.0.0.1.nip.io}"
GITLAB_HOST="${GITLAB_HOST:-gitlab.${GITLAB_DOMAIN}}"
GITLAB_REGISTRY_HOST="${GITLAB_REGISTRY_HOST:-registry.${GITLAB_DOMAIN}}"
GITLAB_WEBSERVICE_SERVICE="${GITLAB_WEBSERVICE_SERVICE:-gitlab-webservice-default}"
GITLAB_WEBSERVICE_HOST="${GITLAB_WEBSERVICE_HOST:-${GITLAB_WEBSERVICE_SERVICE}.${NAMESPACE}.svc.cluster.local}"
RESTART_K3D_NODES="${RESTART_K3D_NODES:-true}"

function require_tool() {
  local tool="$1"

  if ! command -v "${tool}" > /dev/null 2>&1; then
    echo "ERROR: ${tool} is required but not installed."
    exit 1
  fi
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

function k3d_nodes() {
  docker ps \
    --filter "label=app=k3d" \
    --filter "label=k3d.cluster=${K3D_CLUSTER_NAME}" \
    --format '{{.Names}}' |
    awk '/^k3d-.*-(server|agent)-[0-9]+$/ {print}'
}

function node_gateway() {
  local node="$1"

  docker exec "${node}" sh -c "ip route | awk '/^default / {print \$3; exit}'"
}

function service_cluster_ip() {
  if ! command -v kubectl > /dev/null 2>&1; then
    return 0
  fi

  kubectl --context "${KUBE_CONTEXT}" -n "${NAMESPACE}" get service "${GITLAB_WEBSERVICE_SERVICE}" \
    -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true
}

function configure_node() {
  local node="$1"
  local gateway_ip="$2"
  local webservice_ip="$3"

  docker exec -i \
    -e "GATEWAY_IP=${gateway_ip}" \
    -e "GITLAB_WEBSERVICE_HOST=${GITLAB_WEBSERVICE_HOST}" \
    -e "GITLAB_HOST=${GITLAB_HOST}" \
    -e "GITLAB_REGISTRY_HOST=${GITLAB_REGISTRY_HOST}" \
    -e "WEBSERVICE_IP=${webservice_ip}" \
    "${node}" sh <<'NODE_SCRIPT'
set -e

hosts_changed=false
registry_changed=false
begin="# BEGIN gitlabc local GitLab registry"
end="# END gitlabc local GitLab registry"

awk -v begin="${begin}" -v end="${end}" '
  $0 == begin {skip = 1; next}
  $0 == end {skip = 0; next}
  skip != 1 {print}
' /etc/hosts > /tmp/gitlabc-hosts
{
  echo "${begin}"
  echo "${GATEWAY_IP} ${GITLAB_HOST} ${GITLAB_REGISTRY_HOST}"
  if [ -n "${WEBSERVICE_IP}" ]; then
    echo "${WEBSERVICE_IP} ${GITLAB_WEBSERVICE_HOST}"
  fi
  echo "${end}"
} >> /tmp/gitlabc-hosts

if ! cmp -s /etc/hosts /tmp/gitlabc-hosts; then
  cp /tmp/gitlabc-hosts /etc/hosts
  hosts_changed=true
fi

mkdir -p /etc/rancher/k3s
cat > /tmp/gitlabc-registries.yaml <<EOF
configs:
  "${GITLAB_REGISTRY_HOST}":
    tls:
      insecure_skip_verify: true
EOF

if ! cmp -s /etc/rancher/k3s/registries.yaml /tmp/gitlabc-registries.yaml 2>/dev/null; then
  cp /tmp/gitlabc-registries.yaml /etc/rancher/k3s/registries.yaml
  registry_changed=true
fi

if ${hosts_changed} || ${registry_changed}; then
  echo "changed hosts=${hosts_changed} registry=${registry_changed}"
else
  echo "unchanged hosts=false registry=false"
fi
NODE_SCRIPT
}

require_tool docker
validate_boolean RESTART_K3D_NODES "${RESTART_K3D_NODES}"

nodes=()
while IFS= read -r node; do
  [[ -n "${node}" ]] && nodes+=("${node}")
done < <(k3d_nodes)
if [[ "${#nodes[@]}" -eq 0 ]]; then
  echo "ERROR: No k3d server/agent nodes found for cluster '${K3D_CLUSTER_NAME}'."
  exit 1
fi

restart_nodes=()
webservice_ip="$(service_cluster_ip)"
if [[ -n "${webservice_ip}" ]]; then
  echo "GitLab webservice auth host ${GITLAB_WEBSERVICE_HOST} -> ${webservice_ip}"
else
  echo "GitLab webservice service not found yet; skipping internal auth host alias."
fi

for node in "${nodes[@]}"; do
  gateway_ip="$(node_gateway "${node}")"
  if [[ -z "${gateway_ip}" ]]; then
    echo "ERROR: Could not determine Docker gateway IP for ${node}."
    exit 1
  fi

  result="$(configure_node "${node}" "${gateway_ip}" "${webservice_ip}")"
  echo "${node}: ${result}"
  if [[ "${result}" == *"registry=true"* ]]; then
    restart_nodes+=("${node}")
  fi
done

if [[ "${#restart_nodes[@]}" -gt 0 && "${RESTART_K3D_NODES}" == "true" ]]; then
  echo "Restarting changed k3d nodes so k3s/containerd reloads registry config..."
  docker restart "${restart_nodes[@]}"
  for node in "${restart_nodes[@]}"; do
    gateway_ip="$(node_gateway "${node}")"
    result="$(configure_node "${node}" "${gateway_ip}" "${webservice_ip}")"
    echo "${node}: ${result}"
  done
fi

echo "Local GitLab registry pull config is ready for ${K3D_CLUSTER_NAME}."
