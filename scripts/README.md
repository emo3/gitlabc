# Scripts

Small helpers for running a local GitLab installation on k3d. Run them from
the repository root, for example: `bash scripts/check_status.sh`.

| Script | Purpose |
| --- | --- |
| `backup_gitlab.sh` | Create a GitLab backup and copy it, with Rails secrets, to the host. |
| `check_latest_stable.sh` | Compare local version pins with current stable upstream releases. |
| `check_status.sh` | Wait for GitLab to be healthy and print diagnostics on timeout. |
| `configure_gitlab_ssh_key.sh` | Add the local SSH public key to the local GitLab account. |
| `configure_k3d_registry_pull.sh` | Allow k3d nodes to pull from the local GitLab Container Registry. |
| `create_mkcert.sh` | Create and install a locally trusted TLS wildcard certificate for GitLab. |
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
| `update_gitlab_chart_version.sh` | Check for, and optionally apply, an update to the pinned GitLab Helm chart. |
| `update_gitlab_runner_chart_version.sh` | Check the standalone Runner release and optionally upgrade it with its current values. |

## Notes

- Use `bash scripts/<script>.sh -h` when a script supports help.
- Take a backup before `reset_local.sh`, `reset_cluster.sh`, or the Registry metadata migration.
- `reset_cluster.sh` is destructive; with its default settings it also removes unused Docker resources.
