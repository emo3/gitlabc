#!/bin/bash

# Reclaim Docker space without touching k3d/GitLab containers, volumes, or
# networks.  In particular, do not replace this with `docker system prune`:
# stopped k3d node containers are required to restart a stopped GitLab cluster.

set -euo pipefail
[[ -n "${TRACE:-}" ]] && set -x

usage() {
  cat <<'EOF'
Usage: bash scripts/docker_cleanup_safe.sh

With no arguments, install and enable the daily per-user systemd timer if it
is not already enabled and active. The timer runs cleanup that removes only:
  - dangling (untagged) images
  - unused build cache

This script never removes containers, volumes, or networks.  Those may contain
or be required by the local k3d/GitLab installation.

EOF
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SYSTEMD_USER_DIR="${XDG_CONFIG_HOME:-${HOME}/.config}/systemd/user"
SERVICE_NAME="gitlab-docker-cleanup.service"
TIMER_NAME="gitlab-docker-cleanup.timer"

function install_timer() {
  if ! command -v systemctl > /dev/null 2>&1; then
    echo "ERROR: systemd is required to install the cleanup timer."
    exit 1
  fi

  install -d -m 0755 "${SYSTEMD_USER_DIR}"

  cat > "${SYSTEMD_USER_DIR}/${SERVICE_NAME}" <<EOF
[Unit]
Description=Safe Docker cleanup for local GitLab

[Service]
Type=oneshot
WorkingDirectory=${PROJECT_ROOT}
Environment=DOCKER_CLEANUP_RUN=true
ExecStart=/bin/bash ${SCRIPT_DIR}/docker_cleanup_safe.sh
EOF

  cat > "${SYSTEMD_USER_DIR}/${TIMER_NAME}" <<EOF
[Unit]
Description=Daily safe Docker cleanup for local GitLab

[Timer]
OnCalendar=daily
Persistent=true

[Install]
WantedBy=timers.target
EOF

  systemctl --user daemon-reload
  systemctl --user enable --now "${TIMER_NAME}" > /dev/null

  if command -v loginctl > /dev/null 2>&1; then
    loginctl enable-linger "${USER}" > /dev/null
  else
    echo "WARNING: loginctl is unavailable; the timer may not run after reboot until you log in."
  fi

  echo "Installed and enabled ${TIMER_NAME}."
}

function timer_is_installed() {
  systemctl --user is-enabled --quiet "${TIMER_NAME}" > /dev/null 2>&1 \
    && systemctl --user is-active --quiet "${TIMER_NAME}" > /dev/null 2>&1
}

case "${1:-}" in
  "") ;;
  -h|--help) usage; exit 0 ;;
  *)
    usage >&2
    exit 2
    ;;
esac

if [[ "${DOCKER_CLEANUP_RUN:-false}" != "true" ]]; then
  if timer_is_installed; then
    echo "${TIMER_NAME} is already enabled and active; skipping installation."
  else
    install_timer
  fi
  exit 0
fi

if ! command -v docker > /dev/null 2>&1; then
  echo "ERROR: docker is required."
  exit 1
fi

if ! docker info > /dev/null 2>&1; then
  echo "ERROR: Docker is not running or is not accessible by this user."
  exit 1
fi

echo "== Docker disk usage (before) =="
docker system df -v

printf '\nRemoving dangling images...\n'
docker image prune -f

printf '\nRemoving unused build cache...\n'
docker builder prune -f

printf '\n== Docker disk usage (after) ==\n'
docker system df -v

printf '\nCompleted. Containers, volumes, and networks were not removed.\n'
