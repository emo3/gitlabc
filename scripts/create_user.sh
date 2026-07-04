#!/bin/bash

# Create or reset a GitLab user without outbound email.

set -eo pipefail
[[ "${TRACE}" ]] && set -x

NAMESPACE="${NAMESPACE:-gitlab}"
RELEASE_NAME="${RELEASE_NAME:-gitlab}"
K3D_CLUSTER_NAME="${K3D_CLUSTER_NAME:-gitlab-dev}"
KUBE_CONTEXT="${KUBE_CONTEXT:-k3d-${K3D_CLUSTER_NAME}}"
POSTGRES_POD="${POSTGRES_POD:-dev-cluster-1}"
POSTGRES_SECRET="${POSTGRES_SECRET:-dev-cluster-app}"
POSTGRES_USER="${POSTGRES_USER:-gitlab}"
POSTGRES_DB="${POSTGRES_DB:-gitlabhq_production}"

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
  NAMESPACE       Kubernetes namespace (default: gitlab)
  RELEASE_NAME    Helm release name (default: gitlab)
  KUBE_CONTEXT    Kubernetes context (default: k3d-gitlab-dev)
  POSTGRES_POD    PostgreSQL pod (default: dev-cluster-1)
  POSTGRES_SECRET PostgreSQL app secret (default: dev-cluster-app)
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

if ! kubectl config get-contexts "${KUBE_CONTEXT}" > /dev/null 2>&1; then
  echo "ERROR: Kubernetes context '${KUBE_CONTEXT}' was not found."
  exit 1
fi

POSTGRES_PASSWORD_B64="$(
  kubectl --context "${KUBE_CONTEXT}" -n "${NAMESPACE}" get secret "${POSTGRES_SECRET}" \
    -o jsonpath='{.data.password}' 2>/dev/null || true
)"

if [[ -z "${POSTGRES_PASSWORD_B64}" ]]; then
  echo "ERROR: Could not read PostgreSQL password from secret '${POSTGRES_SECRET}' in namespace '${NAMESPACE}'."
  exit 1
fi

POSTGRES_PASSWORD="$(printf '%s' "${POSTGRES_PASSWORD_B64}" | base64 -d)"

function psql_gitlab() {
  kubectl --context "${KUBE_CONTEXT}" -n "${NAMESPACE}" exec -i "${POSTGRES_POD}" -- \
    env PGPASSWORD="${POSTGRES_PASSWORD}" \
    psql -h localhost -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" "$@"
}

EXISTING_USER="$(
  psql_gitlab \
    -v username="${USERNAME}" \
    -v email="${EMAIL}" \
    -tA <<'SQL'
select id || '|' || username || '|' || email
from users
where username = :'username' or email = :'email'
order by id
limit 1;
SQL
)"

if [[ -n "${EXISTING_USER}" && "${UPDATE_EXISTING}" != "true" ]]; then
  IFS='|' read -r existing_id existing_username existing_email <<< "${EXISTING_USER}"
  echo "ERROR: User already exists: id=${existing_id} username=${existing_username} email=${existing_email}"
  echo "Re-run with -U to update password/admin/name/email."
  exit 1
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

PASSWORD_HASH="$(
  kubectl --context "${KUBE_CONTEXT}" -n "${NAMESPACE}" exec "${TOOLBOX_POD}" -c toolbox -- \
    env GITLAB_CREATE_USER_PASSWORD="${PASSWORD}" \
    /srv/gitlab/bin/bundle exec ruby -rbcrypt -e 'puts BCrypt::Password.create(ENV.fetch("GITLAB_CREATE_USER_PASSWORD"), cost: 13)'
)"

if [[ -z "${PASSWORD_HASH}" ]]; then
  echo "ERROR: Failed to generate bcrypt password hash."
  exit 1
fi

if [[ -n "${EXISTING_USER}" ]]; then
  psql_gitlab \
    -v username="${USERNAME}" \
    -v email="${EMAIL}" \
    -v name="${NAME}" \
    -v password_hash="${PASSWORD_HASH}" \
    -v admin="${ADMIN}" \
    -v onboarding_status='{"setup_for_company":false,"email_opt_in":false}' \
    -v ON_ERROR_STOP=1 <<'SQL'
update users
set email = :'email',
    name = :'name',
    encrypted_password = :'password_hash',
    admin = case when :'admin' = 'true' then true else admin end,
    confirmed_at = coalesce(confirmed_at, now()),
    onboarding_in_progress = false,
    updated_at = now()
where username = :'username' or email = :'email';

update emails
set email = :'email',
    confirmed_at = coalesce(confirmed_at, now()),
    updated_at = now()
where user_id = (select id from users where username = :'username' or email = :'email' order by id limit 1);

update user_details
set onboarding_status = :'onboarding_status'::jsonb
where user_id = (select id from users where username = :'username' or email = :'email' order by id limit 1);

update user_preferences
set setup_for_company = false,
    updated_at = now()
where user_id = (select id from users where username = :'username' or email = :'email' order by id limit 1);
SQL
  ACTION="updated"
else
  psql_gitlab \
    -v username="${USERNAME}" \
    -v email="${EMAIL}" \
    -v name="${NAME}" \
    -v password_hash="${PASSWORD_HASH}" \
    -v admin="${ADMIN}" \
    -v onboarding_status='{"setup_for_company":false,"email_opt_in":false}' \
    -v ON_ERROR_STOP=1 <<'SQL'
begin;

create temporary table create_gitlab_user_ids(user_id bigint, namespace_id bigint) on commit drop;

with org as (
  select id from organizations order by id limit 1
),
new_user as (
  insert into users (
    email, encrypted_password, created_at, updated_at, name, admin,
    projects_limit, username, can_create_group, can_create_team, state,
    confirmed_at, notification_email, external, preferred_language,
    user_type, onboarding_in_progress, organization_id, password_automatically_set
  )
  values (
    :'email', :'password_hash', now(), now(), :'name', (:'admin' = 'true'),
    100000, :'username', true, false, 'active',
    now(), '', false, 'en',
    0, false, (select id from org), false
  )
  returning id
),
new_namespace as (
  insert into namespaces (
    name, path, owner_id, created_at, updated_at, type, visibility_level,
    request_access_enabled, organization_id, state, traversal_ids
  )
  select :'name', :'username', id, now(), now(), 'User', 20,
         true, (select id from org), 0, '{}'::bigint[]
  from new_user
  returning id, owner_id
)
insert into create_gitlab_user_ids(user_id, namespace_id)
select owner_id, id from new_namespace;

update namespaces
set traversal_ids = array[id]::bigint[]
where id = (select namespace_id from create_gitlab_user_ids);

insert into routes(source_id, source_type, path, created_at, updated_at, name, namespace_id)
select namespace_id, 'Namespace', :'username', now(), now(), :'name', namespace_id
from create_gitlab_user_ids;

insert into user_details(user_id, onboarding_status)
select user_id, :'onboarding_status'::jsonb
from create_gitlab_user_ids;

insert into user_preferences(user_id, created_at, updated_at, setup_for_company)
select user_id, now(), now(), false
from create_gitlab_user_ids;

insert into emails(user_id, email, created_at, updated_at, confirmed_at)
select user_id, :'email', now(), now(), now()
from create_gitlab_user_ids;

commit;
SQL
  ACTION="created"
fi

RESULT="$(
  psql_gitlab \
    -v username="${USERNAME}" \
    -v email="${EMAIL}" \
    -tA <<'SQL'
select username || '|' || email || '|' || admin
from users
where username = :'username' or email = :'email'
order by id
limit 1;
SQL
)"

IFS='|' read -r result_username result_email result_admin <<< "${RESULT}"
echo "${ACTION} username=${result_username} email=${result_email} admin=${result_admin}"

if [[ "${GENERATED_PASSWORD}" == "true" ]]; then
  echo "Generated password for ${USERNAME}: ${PASSWORD}"
fi
