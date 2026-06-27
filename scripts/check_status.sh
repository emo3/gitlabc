#!/bin/bash

# Wait for the local GitLab namespace to become healthy, then print diagnostics
# if it does not settle within the timeout.

set -eo pipefail
[[ "${TRACE}" ]] && set -x

NAMESPACE="${NAMESPACE:-gitlab}"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-600}"
SLEEP_SECONDS="${SLEEP_SECONDS:-10}"
K3D_CLUSTER_NAME="${K3D_CLUSTER_NAME:-gitlab-dev}"
KUBE_CONTEXT="${KUBE_CONTEXT:-k3d-${K3D_CLUSTER_NAME}}"

KUBECTL=(kubectl --context "${KUBE_CONTEXT}" -n "${NAMESPACE}")

function context_exists() {
  kubectl config get-contexts "${KUBE_CONTEXT}" > /dev/null 2>&1
}

function namespace_exists() {
  kubectl --context "${KUBE_CONTEXT}" get namespace "${NAMESPACE}" > /dev/null 2>&1
}

function pods_ready() {
  local not_ready
  not_ready="$("${KUBECTL[@]}" get pods --no-headers 2>/dev/null | awk '
    $3 == "Completed" { next }
    $3 == "Succeeded" { next }
    {
      split($2, ready, "/")
      if ($3 != "Running" || ready[1] != ready[2]) {
        print
      }
    }')"

  [[ -z "${not_ready}" ]]
}

function jobs_ready() {
  local not_ready
  not_ready="$("${KUBECTL[@]}" get jobs --no-headers 2>/dev/null | awk '
    {
      split($3, complete, "/")
      if ($2 != "Complete" && complete[1] != complete[2]) {
        print
      }
    }')"

  [[ -z "${not_ready}" ]]
}

function ingress_ready() {
  "${KUBECTL[@]}" get ingress gitlab-webservice-default > /dev/null 2>&1
}

function print_wait_reasons() {
  local not_ready_pods
  local not_ready_jobs

  not_ready_pods="$("${KUBECTL[@]}" get pods --no-headers 2>/dev/null | awk '
    $3 == "Completed" { next }
    $3 == "Succeeded" { next }
    {
      split($2, ready, "/")
      if ($3 != "Running" || ready[1] != ready[2]) {
        print "  pod " $0
      }
    }')"

  not_ready_jobs="$("${KUBECTL[@]}" get jobs --no-headers 2>/dev/null | awk '
    {
      split($3, complete, "/")
      if ($2 != "Complete" && complete[1] != complete[2]) {
        print "  job " $0
      }
    }')"

  if [[ -n "${not_ready_pods}" ]]; then
    echo "${not_ready_pods}"
  fi

  if [[ -n "${not_ready_jobs}" ]]; then
    echo "${not_ready_jobs}"
  fi

  if ! ingress_ready; then
    echo "  ingress gitlab-webservice-default is missing"
  fi
}

function print_status() {
  echo ""
  echo "== Pods =="
  "${KUBECTL[@]}" get pods -o wide || true

  echo ""
  echo "== Jobs =="
  "${KUBECTL[@]}" get jobs || true

  echo ""
  echo "== Ingress =="
  "${KUBECTL[@]}" get ingress || true

  echo ""
  echo "== Helm releases =="
  helm list -n "${NAMESPACE}" --kube-context "${KUBE_CONTEXT}" || true
}

function print_issues() {
  echo ""
  echo "Timed out after ${TIMEOUT_SECONDS}s. Focused diagnostics:"

  echo ""
  echo "== Non-ready pods =="
  "${KUBECTL[@]}" get pods --no-headers 2>/dev/null | awk '
    $3 == "Completed" { next }
    $3 == "Succeeded" { next }
    {
      split($2, ready, "/")
      if ($3 != "Running" || ready[1] != ready[2]) {
        print $0
      }
    }' || true

  echo ""
  echo "== Incomplete jobs =="
  "${KUBECTL[@]}" get jobs --no-headers 2>/dev/null | awk '
    {
      split($3, complete, "/")
      if ($2 != "Complete" && complete[1] != complete[2]) {
        print $0
      }
    }' || true

  echo ""
  echo "== Ingress check =="
  if ingress_ready; then
    "${KUBECTL[@]}" get ingress gitlab-webservice-default || true
  else
    echo "ingress/gitlab-webservice-default is missing"
  fi

  echo ""
  echo "== Recent warnings/events =="
  "${KUBECTL[@]}" get events --sort-by=.lastTimestamp 2>/dev/null | tail -40 || true

  echo ""
  echo "== Describe non-ready pods =="
  while read -r pod _; do
    [[ -z "${pod}" ]] && continue
    echo ""
    echo "--- ${pod} ---"
    "${KUBECTL[@]}" describe pod "${pod}" || true
  done < <("${KUBECTL[@]}" get pods --no-headers 2>/dev/null | awk '
    $3 == "Completed" { next }
    $3 == "Succeeded" { next }
    {
      split($2, ready, "/")
      if ($3 != "Running" || ready[1] != ready[2]) {
        print $1
      }
    }')

  echo ""
  echo "== Logs from non-ready pods =="
  while read -r pod _; do
    [[ -z "${pod}" ]] && continue
    echo ""
    echo "--- ${pod} ---"
    "${KUBECTL[@]}" logs "${pod}" --all-containers --tail=80 || true
  done < <("${KUBECTL[@]}" get pods --no-headers 2>/dev/null | awk '
    $3 == "Completed" { next }
    $3 == "Succeeded" { next }
    {
      split($2, ready, "/")
      if ($3 != "Running" || ready[1] != ready[2]) {
        print $1
      }
    }')
}

if ! context_exists; then
  echo "ERROR: Kubernetes context '${KUBE_CONTEXT}' was not found."
  echo "This profile uses k3d. Run the Ansible playbook to create the context, or set KUBE_CONTEXT."
  exit 1
fi

if ! namespace_exists; then
  echo "ERROR: Namespace '${NAMESPACE}' was not found in context '${KUBE_CONTEXT}'."
  exit 1
fi

echo "Waiting up to ${TIMEOUT_SECONDS}s for namespace '${NAMESPACE}' in context '${KUBE_CONTEXT}'..."

deadline=$((SECONDS + TIMEOUT_SECONDS))
while (( SECONDS < deadline )); do
  if pods_ready && jobs_ready && ingress_ready; then
    echo "GitLab namespace is healthy."
    print_status
    exit 0
  fi

  echo "Still waiting..."
  print_wait_reasons || true
  sleep "${SLEEP_SECONDS}"
done

print_issues
exit 1
