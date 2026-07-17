# Local GitLab on k3d

Run GitLab locally on Linux or macOS with k3d and the upstream GitLab Helm
chart.

## Quick start

Keep this repository beside the upstream chart checkout:

```text
$HOME/code/
  gitlabc/
  gitlab/
```

```bash
cd "$HOME/code"
git clone https://gitlab.com/gitlab-org/charts/gitlab.git  # if missing
cd gitlabc
```

Install Ansible

- AlmaLinux: `sudo dnf install -y ansible-core`
- MacOS: `brew install ansible`

Choose and configure one HTTPS profile:

- [Local/LAN HTTPS with mkcert](README-mk.md) — default
- [Public HTTPS with Let's Encrypt](README-le.md)

Then start GitLab:

```bash
bash scripts/start_gitlab.sh
```

## Daily use

Run these commands from `gitlabc`:

| Task | Command |
| --- | --- |
| Start | `bash scripts/start_gitlab.sh` |
| Stop without deleting data | `bash scripts/stop_gitlab.sh` |
| Check health | `bash scripts/check_status.sh` |
| Back up | `bash scripts/backup_gitlab.sh` |
| List backups | `bash scripts/restore_gitlab.sh -l` |

See [scripts/README.md](scripts/README.md) for all helpers.

Restoring overwrites GitLab data. After reviewing the available backups, run
`bash scripts/restore_gitlab.sh` to restore the newest one.

## Login

Sign in as `root`. Get the initial password with:

```bash
kubectl get secret -n gitlab gitlab-gitlab-initial-root-password \
  -o go-template='{{index .data "password" | base64decode}}{{"\n"}}'
```

After restoring a backup, the secret may be stale. Reset `root` instead:

```bash
bash scripts/create_user.sh \
  -u root -e root@example.com -n Administrator -a -U
```

## Data and reset

A normal stop/start preserves data. Both reset commands delete GitLab data, so
back up first.

```bash
# Keep the k3d cluster
bash scripts/reset_local.sh

# Delete the cluster and prune unused Docker data
bash scripts/reset_cluster.sh
```

Set `PRUNE_DOCKER=false` when running `reset_cluster.sh` to skip Docker pruning.

To move GitLab between hosts, use the backup/restore helpers; do not copy k3d
or Docker volumes. See the `gitlab-vip.sh` notes in
[scripts/README.md](scripts/README.md#move-the-lan-address).
