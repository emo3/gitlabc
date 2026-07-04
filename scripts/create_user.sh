#!/bin/bash

# Create or reset a GitLab user without outbound email.

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
UPDATE_EXISTING="false"

function usage() {
  local exit_code="${1:-1}"

  cat <<EOF
Usage: $0 -u USERNAME -e EMAIL [-n NAME] [-p PASSWORD] [-a] [-U]

Creates the user if missing.
If the user already exists, use -U to update it.
If -p is omitted, the script generates an 8-character password and prints it.

Options:
  -u USERNAME  GitLab username.
  -e EMAIL     GitLab email address.
  -n NAME      Display name. Defaults to USERNAME.
  -p PASSWORD  Password. Defaults to a generated password.
  -a           Make the user an admin.
  -U           Update an existing user or reset their password.
  -h           Show this help.

Environment:
  NAMESPACE    Kubernetes namespace (default: gitlab)
  RELEASE_NAME Helm release name (default: gitlab)
  KUBE_CONTEXT Kubernetes context (default: k3d-gitlab-dev)
EOF
  exit "${exit_code}"
}

function generate_password() {
  if ! command -v openssl >/dev/null 2>&1; then
    echo "ERROR: openssl is required to generate a password. Install openssl or pass -p." >&2
    exit 1
  fi

  printf 'A%s!\n' "$(openssl rand -hex 3)"
}

function running_toolbox_pod() {
  kubectl --context "${KUBE_CONTEXT}" -n "${NAMESPACE}" get pod \
    -l "release=${RELEASE_NAME},app=toolbox" \
    --field-selector=status.phase=Running \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -u)
      USERNAME="${2:-}"
      shift 2
      ;;
    -e)
      EMAIL="${2:-}"
      shift 2
      ;;
    -n)
      NAME="${2:-}"
      shift 2
      ;;
    -p)
      PASSWORD="${2:-}"
      shift 2
      ;;
    -a)
      ADMIN="true"
      shift
      ;;
    -U)
      UPDATE_EXISTING="true"
      shift
      ;;
    -h)
      usage 0
      ;;
    *)
      echo "ERROR: Unknown argument: $1"
      usage
      ;;
  esac
done

if [[ -z "${USERNAME}" || -z "${EMAIL}" ]]; then
  echo "ERROR: -u USERNAME and -e EMAIL are required."
  usage
fi

if [[ -z "${NAME}" ]]; then
  NAME="${USERNAME}"
fi

GENERATED_PASSWORD="false"
if [[ -z "${PASSWORD}" ]]; then
  PASSWORD="$(generate_password)"
  GENERATED_PASSWORD="true"
fi

if [[ -z "${PASSWORD}" ]]; then
  echo "ERROR: Password must not be empty."
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

RESULT="$(
  kubectl --context "${KUBE_CONTEXT}" -n "${NAMESPACE}" exec "${TOOLBOX_POD}" -c toolbox -- \
    env \
      GITLAB_CREATE_USER_USERNAME="${USERNAME}" \
      GITLAB_CREATE_USER_EMAIL="${EMAIL}" \
      GITLAB_CREATE_USER_NAME="${NAME}" \
      GITLAB_CREATE_USER_PASSWORD="${PASSWORD}" \
      GITLAB_CREATE_USER_ADMIN="${ADMIN}" \
      GITLAB_CREATE_USER_UPDATE="${UPDATE_EXISTING}" \
      gitlab-rails runner '
username = ENV.fetch("GITLAB_CREATE_USER_USERNAME")
email = ENV.fetch("GITLAB_CREATE_USER_EMAIL")
name = ENV.fetch("GITLAB_CREATE_USER_NAME")
password = ENV.fetch("GITLAB_CREATE_USER_PASSWORD")
admin = ENV.fetch("GITLAB_CREATE_USER_ADMIN") == "true"
update_existing = ENV.fetch("GITLAB_CREATE_USER_UPDATE") == "true"

user = User.find_by(username: username) || User.find_by(email: email)

if user && !update_existing
  warn "ERROR: User already exists: id=#{user.id} username=#{user.username} email=#{user.email}"
  warn "Re-run with -U to update password/admin/name/email."
  exit 10
end

action = user ? "updated" : "created"
user ||= User.new(username: username)

user.email = email
user.name = name
user.password = password
user.password_confirmation = password
user.admin = true if admin
user.external = false if user.respond_to?(:external=)
user.preferred_language = "en" if user.respond_to?(:preferred_language=)
user.password_automatically_set = false if user.respond_to?(:password_automatically_set=)
user.onboarding_in_progress = false if user.respond_to?(:onboarding_in_progress=)
user.skip_confirmation! if user.respond_to?(:skip_confirmation!)
user.skip_reconfirmation! if user.respond_to?(:skip_reconfirmation!)
user.confirmed_at = Time.current if user.respond_to?(:confirmed_at=) && user.confirmed_at.nil?

if user.respond_to?(:user_detail) && user.user_detail
  user.user_detail.onboarding_status = { setup_for_company: false, email_opt_in: false }
end

user.save!

puts "#{action}|#{user.username}|#{user.email}|#{user.admin?}"
'
)"

IFS='|' read -r action result_username result_email result_admin <<< "${RESULT##*$'\n'}"
echo "${action} username=${result_username} email=${result_email} admin=${result_admin}"

if [[ "${GENERATED_PASSWORD}" == "true" ]]; then
  echo "Generated password for ${USERNAME}: ${PASSWORD}"
fi
