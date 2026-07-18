# Scripts

Small helpers for running a local GitLab installation on k3d. Run them from
the repository root, for example: `bash scripts/check_status.sh`.

| Script | Purpose |
| --- | --- |
| `backup_gitlab.sh` | Create a GitLab backup and copy it, with Rails secrets, to the host. |
| `check_latest_stable.sh` | Compare local version pins, including the sibling Runner chart pin when present, with current stable upstream releases. |
| `check_status.sh` | Wait for GitLab to be healthy and print diagnostics on timeout. |
| `configure_gitlab_ssh_key.sh` | Add the local SSH public key to the local GitLab account. |
| `configure_k3d_registry_pull.sh` | Allow k3d nodes to pull from the local GitLab Container Registry. |
| `create_mkcert.sh` | Create and install a locally trusted TLS wildcard certificate for GitLab. |
| `docker_cleanup_safe.sh` | Prune only dangling images and build cache; can install a daily systemd timer. |
| `create_user.sh` | Create or reset a GitLab user without sending email. |
| `deploy_gitlab.sh` | Install or upgrade the GitLab Helm release. |
| `dev_dependencies.sh` | Set up or tear down GitLab's local supporting dependencies. |
| `import_github_project.sh` | Import a GitHub repository into a local GitLab group. |
| `migrate_registry_metadata_database.sh` | One-time migration of Registry metadata from object storage to PostgreSQL. |
| `reset_cluster.sh` | Remove GitLab and the entire k3d cluster; it may also prune Docker data. |
| `reset_local.sh` | Remove GitLab while keeping the k3d cluster. |
| `restore_gitlab.sh` | Restore a GitLab backup archive into the local deployment. |
| `start_gitlab.sh` | Reconcile prerequisites, deploy GitLab, and wait for it to become healthy. |
| `stop_gitlab.sh` | Stop the k3d cluster while retaining GitLab data. |

## Notes

- Use `bash scripts/<script>.sh -h` when a script supports help.
- Use `check_latest_stable.sh -a -r -H` to update drifting pins and rerun the
  relevant idempotent Ansible/deploy workflows. Its Ansible step does not create
  or start k3d; use `start_gitlab.sh` when cluster lifecycle management is wanted.
  Use `-s` without `-a` for an audit that requires manual review before changes.
- `check_status.sh`, `start_gitlab.sh`, `stop_gitlab.sh`, and the reset,
  deploy, certificate, and configuration helpers take their settings from
  environment variables rather than command-line arguments.
- Take a backup before `reset_local.sh`, `reset_cluster.sh`, or the Registry metadata migration.
- `reset_cluster.sh` is destructive; with its default settings it also removes unused Docker resources.
- Run `bash scripts/docker_cleanup_safe.sh` once to install its idempotent daily per-user systemd timer. Later runs skip installation when that timer is enabled and active. The timer reclaims Docker space without deleting k3d/GitLab data and reports usage before and after cleanup.

## Common operations

```bash
# Back up (saves the archive and Rails secrets in .backups/)
bash scripts/backup_gitlab.sh

# List or restore backups; restoring overwrites current GitLab data
bash scripts/restore_gitlab.sh -l
bash scripts/restore_gitlab.sh

# Run safe Docker cleanup now (never removes containers, volumes, or networks)
DOCKER_CLEANUP_RUN=true bash scripts/docker_cleanup_safe.sh

# One-time Registry migration; do not push/delete images until it completes
REGISTRY_METADATA_MIGRATION_CONFIRM=true \
  bash scripts/migrate_registry_metadata_database.sh
```

Keep the backup archive and Rails secrets together; both are needed to restore.
Use `TIMEOUT_SECONDS=<seconds>` to extend `check_status.sh` beyond its
720-second default.

## Stable LAN endpoint

Run GitLab on AlmaLinux with the configured `GITLAB_EXTERNAL_IP` as a
permanent secondary address on its NetworkManager connection. Reserve that
address in DHCP. This keeps the GitLab URL stable without a host-to-host VIP
handoff mechanism.

Use `backup_gitlab.sh` and `restore_gitlab.sh` to recover GitLab on a separate
host; that recovery host uses its own LAN address.
