#!/bin/bash

# Create or update a GitLab user through the toolbox pod.

set -eo pipefail
[[ "${TRACE}" ]] && set -x

NAMESPACE="${NAMESPACE:-gitlab}"
RELEASE_NAME="${RELEASE_NAME:-gitlab}"
K3D_CLUSTER_NAME="${K3D_CLUSTER_NAME:-gitlab-dev}"
KUBE_CONTEXT="${KUBE_CONTEXT:-k3d-${K3D_CLUSTER_NAME}}"

USERNAME=""
EMAIL=""
NAME=""
PASSWORD="${GITLAB_USER_PASSWORD:-}"
ADMIN="false"

function usage() {
  cat <<EOF
Usage: $0 --username USERNAME --email EMAIL [--name NAME] [--password PASSWORD] [--admin]

Creates the user if missing, or updates the password for an existing user.
If --password is omitted, the script prompts for it without echoing.

Environment:
  NAMESPACE       Kubernetes namespace (default: gitlab)
  RELEASE_NAME    Helm release name (default: gitlab)
  KUBE_CONTEXT    Kubernetes context (default: k3d-gitlab-dev)
EOF
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --username)
      USERNAME="${2:-}"
      shift 2
      ;;
    --email)
      EMAIL="${2:-}"
      shift 2
      ;;
    --name)
      NAME="${2:-}"
      shift 2
      ;;
    --password)
      PASSWORD="${2:-}"
      shift 2
      ;;
    --admin)
      ADMIN="true"
      shift
      ;;
    -h|--help)
      usage
      ;;
    *)
      echo "ERROR: Unknown argument: $1"
      usage
      ;;
  esac
done

if [[ -z "${USERNAME}" || -z "${EMAIL}" ]]; then
  echo "ERROR: --username and --email are required."
  usage
fi

if [[ -z "${NAME}" ]]; then
  NAME="${USERNAME}"
fi

if [[ -z "${PASSWORD}" ]]; then
  read -r -s -p "Password for ${USERNAME}: " PASSWORD
  echo
  read -r -s -p "Confirm password: " PASSWORD_CONFIRM
  echo

  if [[ "${PASSWORD}" != "${PASSWORD_CONFIRM}" ]]; then
    echo "ERROR: Passwords do not match."
    exit 1
  fi
fi

if [[ -z "${PASSWORD}" ]]; then
  echo "ERROR: Password must not be empty."
  exit 1
fi

if ! kubectl config get-contexts "${KUBE_CONTEXT}" > /dev/null 2>&1; then
  echo "ERROR: Kubernetes context '${KUBE_CONTEXT}' was not found."
  exit 1
fi

TOOLBOX_POD="$(
  kubectl --context "${KUBE_CONTEXT}" -n "${NAMESPACE}" get pod \
    -l "release=${RELEASE_NAME},app=toolbox" \
    --field-selector=status.phase=Running \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true
)"

if [[ -z "${TOOLBOX_POD}" ]]; then
  echo "ERROR: No running toolbox pod found for release '${RELEASE_NAME}' in namespace '${NAMESPACE}'."
  echo "Run: bash scripts/check_status.sh"
  exit 1
fi

kubectl --context "${KUBE_CONTEXT}" -n "${NAMESPACE}" exec "${TOOLBOX_POD}" -c toolbox -- \
  env \
    GITLAB_CREATE_USER_USERNAME="${USERNAME}" \
    GITLAB_CREATE_USER_EMAIL="${EMAIL}" \
    GITLAB_CREATE_USER_NAME="${NAME}" \
    GITLAB_CREATE_USER_PASSWORD="${PASSWORD}" \
    GITLAB_CREATE_USER_ADMIN="${ADMIN}" \
    gitlab-rails runner '
username = ENV.fetch("GITLAB_CREATE_USER_USERNAME")
email = ENV.fetch("GITLAB_CREATE_USER_EMAIL")
name = ENV.fetch("GITLAB_CREATE_USER_NAME")
password = ENV.fetch("GITLAB_CREATE_USER_PASSWORD")
admin = ENV.fetch("GITLAB_CREATE_USER_ADMIN") == "true"

user = User.find_by(username: username) || User.find_by(email: email)
created = user.nil?

user ||= User.new
user.username = username
user.email = email
user.name = name
user.password = password
user.password_confirmation = password
user.admin = admin if admin
user.skip_confirmation! if user.respond_to?(:skip_confirmation!)
user.skip_reconfirmation! if user.respond_to?(:skip_reconfirmation!)
user.confirmed_at ||= Time.current if user.respond_to?(:confirmed_at)
user.save!

puts "#{created ? "created" : "updated"} username=#{user.username} email=#{user.email} admin=#{user.admin?}"
'
