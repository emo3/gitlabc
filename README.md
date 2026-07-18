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
| Install daily safe Docker cleanup | `bash scripts/docker_cleanup_safe.sh` |

See [scripts/README.md](scripts/README.md) for all helpers.

Restoring overwrites GitLab data. After reviewing the available backups, run
`bash scripts/restore_gitlab.sh` to restore the newest one.

## Migrate GitLab to another host

Use the backup/restore helpers to move GitLab; do not copy k3d or Docker
volumes. Configure the destination host's endpoint *before* starting GitLab.
The old host's IP address will not work unless it is assigned to the new host.
`restore_gitlab.sh` overwrites the destination GitLab data, so run it only
when that is intended.

1. Copy the backup archive and its Rails secrets file to `gitlabc/.backups/`
   on the destination host.
2. Configure the destination host's stable LAN address. Copy
   `.gitlab.env.example` to `.gitlab.env`, then set
   `GITLAB_DOMAIN`, `GITLAB_EXTERNAL_IP`, and `GITLAB_SSH_HOST` to that
   address. For the local HTTPS profile, also reserve the address in DHCP and
   make it a permanent secondary address on the active AlmaLinux NetworkManager
   connection. Confirm that it is unused first, then replace the connection
   name, device, address, and prefix below as appropriate for the LAN:

   ```bash
   nmcli connection show --active
   sudo arping -D -c 3 -I <device> <gitlab-external-ip>
   sudo nmcli connection modify "<connection-name>" \
     +ipv4.addresses <gitlab-external-ip>/<prefix>
   sudo nmcli device reapply <device>
   ```

   `arping` must receive no replies before the address is assigned. Open the
   host firewall ports as well:

   ```bash
   sudo firewall-cmd --permanent --add-service=http
   sudo firewall-cmd --permanent --add-service=https
   sudo firewall-cmd --permanent --add-port=2222/tcp
   sudo firewall-cmd --reload
   ```

   See [Local/LAN HTTPS with mkcert](README-mk.md) for the HTTPS profile.
3. Start a fresh destination deployment, restore the backup, and verify it:

   ```bash
   cd "$HOME/code/gitlabc"
   bash scripts/start_gitlab.sh
   bash scripts/restore_gitlab.sh
   bash scripts/check_status.sh
   ```

4. Browse to `https://gitlab.${GITLAB_DOMAIN}/users/sign_in`. If the address
   changed after a certificate was created, regenerate it with
   `FORCE_REGENERATE_CERT=true bash scripts/create_mkcert.sh` and rerun
   `bash scripts/start_gitlab.sh`.
5. If CI is used and the restored Runner is offline, reset its authentication
   token once and deploy the Runner release on the new cluster. Follow [GitLab
   Runner recovery instructions](../gitlabr/README.md#after-restoring-gitlab-kis);
   a GitLab backup restores the Runner record but not its Helm release or local
   credential files. Runner token reset is not idempotent; deployment is.
6. After the new host is verified, stop or power off the old host. Do not leave
   both hosts able to claim the same GitLab endpoint address. If the old host
   has the endpoint as a configured secondary address, remove it before that
   host is returned to the LAN:

   ```bash
   nmcli connection show --active
   nmcli connection show "<connection-name>" | grep ipv4.addresses
   sudo nmcli connection modify "<connection-name>" \
     -ipv4.addresses <gitlab-external-ip>/<prefix>
   sudo nmcli device reapply <device>
   ```

   If the endpoint was instead the old host's DHCP primary address, do not use
   the removal command. Keep the old host offline and move its DHCP reservation
   to the new host. Retain the old host unchanged until the migration is
   accepted, so it remains available for rollback.

## Runner offline

The GitLab Runner is a separate Helm release managed by the sibling `gitlabr`
repository; it is not installed by this GitLab chart. GitLab can therefore
retain a runner record while its Kubernetes release is absent, causing the
runner to appear offline.

Check and recover the runner with:

```bash
cd "$HOME/code/gitlabr"
bash scripts/recover_runner.sh
bash scripts/check_runner.sh -s
```

If the runner release was intentionally removed, redeploy it with
`bash scripts/deploy_runner.sh`. Do not use `reset_runner.sh` for recovery; it
uninstalls the runner release. After restoring GitLab from a backup, the saved
runner authentication token may also need to be reset. See the
[GitLab Runner recovery instructions](../gitlabr/README.md#after-restoring-gitlab-kis)
for the token-reset procedure and required local credential files.

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

The primary AlmaLinux host uses a permanent secondary LAN address for its
stable GitLab endpoint; see
[scripts/README.md](scripts/README.md#stable-lan-endpoint).
