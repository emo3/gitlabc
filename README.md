# Local GitLab chart notes

Use this profile to run GitLab on k3d. Choose one HTTPS guide before deploying:

- [Local HTTPS with mkcert](README-mk.md) — the default, for a workstation or LAN.
- [Public HTTPS with Let's Encrypt](README-le.md) — for a publicly reachable domain.

## GitLab Release Cadence

GitLab release cadence is documented in the official [GitLab release and maintenance policy](https://docs.gitlab.com/policy/maintenance/):

- Major releases: yearly, scheduled for May by default.
- Minor releases: monthly, on the third Thursday of each month.
- Patch releases: twice monthly, on the Wednesday before and the Wednesday after the monthly minor release.

## Expected Directory Layout

This profile lives in `gitlabc` and expects the upstream GitLab chart checkout next to it:

```text
$HOME/code/
  gitlabc/   # local scripts, Ansible playbook, generated values
  gitlab/    # upstream gitlab-org/charts/gitlab checkout
```

Clone the upstream chart if it is missing:

```bash
cd $HOME/code
git clone https://gitlab.com/gitlab-org/charts/gitlab.git
```

## Ansible playbooks overview

- `ansible-install-k8s-tools-gitlab-deps.yml` — installs Docker, `kubectl`, Helm 4, `glab`, the `helm-git` plugin, k3d, and mkcert; creates the `gitlab-dev` cluster; switches kubeconfig to `k3d-gitlab-dev`; and verifies Kubernetes is reachable.

## Start here

Run the shared prerequisites from the `gitlabc` directory:

```bash
cd $HOME/code/gitlabc
ansible-playbook -i localhost, --connection=local ansible-install-k8s-tools-gitlab-deps.yml
```

Then follow exactly one deployment guide:

- [Local HTTPS with mkcert](README-mk.md)
- [Public HTTPS with Let's Encrypt](README-le.md)

The deploy profile defaults to `local-mkcert`. The Let's Encrypt guide stores
`GITLAB_DEPLOY_PROFILE=public-letsencrypt` in `.gitlab.env`, so shared
redeployment and recovery commands below retain that choice.

Garage object storage is installed with Kubernetes PVC persistence enabled by
default. The default Garage PVC sizes are `1Gi` for metadata and `10Gi` for
data; override them with `GARAGE_META_PERSISTENCE_SIZE` and
`GARAGE_DATA_PERSISTENCE_SIZE` before dependency setup. For disposable test
runs only, set `GARAGE_PERSISTENCE_ENABLED=false`. This default applies to new
Garage installs; an existing Garage release created without persistence must be
reinstalled or upgraded explicitly before it has persistent object storage.

### Common operations

| Task | Command |
| --- | --- |
| Check health | `bash scripts/check_status.sh` |
| Configure k3d registry pulls | `bash scripts/configure_k3d_registry_pull.sh` |
| Activate/deactivate the GitLab LAN IP on this host | `bash scripts/gitlab-vip.sh activate` / `bash scripts/gitlab-vip.sh deactivate` |
| Start and reconcile local GitLab | `bash "$HOME/code/gitlabc/scripts/start_gitlab.sh"` |
| Stop without deleting data | `bash "$HOME/code/gitlabc/scripts/stop_gitlab.sh"` |
| Back up GitLab | `bash scripts/backup_gitlab.sh` |
| Restore GitLab | `bash scripts/restore_gitlab.sh -l` then `bash scripts/restore_gitlab.sh` |
| Check or update the standalone Runner | `bash scripts/update_gitlab_runner_chart_version.sh` |
| Import a GitHub project | `bash scripts/import_github_project.sh -r emo3/my_repo` |
| Create a local user | `bash scripts/create_user.sh -u alice -e alice@example.com -n "Alice Example"` |
| Destructive local reset | `bash scripts/reset_local.sh` |

For the complete list of helpers, including one-time migration and maintenance
commands, see [scripts/README.md](scripts/README.md).

`configure_k3d_registry_pull.sh` is for the standalone Kubernetes runner. It
lets k3d nodes pull `registry.192.168.86.50.nip.io` images directly through the
local GitLab HTTPS ingress.

`start_gitlab.sh` can be run from any directory. By default, it idempotently
reconciles privileged prerequisites, starts or creates the k3d cluster as
needed, reconciles the GitLab Helm deployment, and waits until GitLab is
healthy. It may prompt for privilege escalation through Ansible.
`stop_gitlab.sh` stops the
k3d cluster only; it retains GitLab data.

### Move GitLab between AlmaLinux and macOS

For the `gitlab.192.168.86.50.nip.io` endpoint, run GitLab on only one host at
a time. The helper assigns or removes the configured `GITLAB_EXTERNAL_IP` on
the current host, and refuses activation if another device answers for it:

```bash
# On the old active host
bash scripts/stop_gitlab.sh
bash scripts/gitlab-vip.sh deactivate

# On the replacement host, after restoring its GitLab backup
bash scripts/gitlab-vip.sh activate
bash scripts/start_gitlab.sh
```

The macOS address change is temporary and must be repeated after a reboot or
Wi-Fi reconnect. On AlmaLinux it is persisted in the active NetworkManager
connection. Reserve the IP for the active host in the router when possible,
and never activate it on both machines.

### Import GitHub projects

After GitLab is deployed, authenticate `glab` against the local GitLab host
using the repo-local config directory:

```bash
GITLAB_DOMAIN="${GITLAB_DOMAIN:-192.168.86.50.nip.io}"
XDG_CONFIG_HOME=../.glab-config glab auth login \
  --hostname "gitlab.${GITLAB_DOMAIN}" \
  --api-host "gitlab.${GITLAB_DOMAIN}" \
  --api-protocol https \
  --git-protocol ssh \
  --web \
  --container-registry-domains ''
```

Then import a GitHub project into the default `netcool` group:

```bash
bash scripts/import_github_project.sh -r tcr_db2
```

The script accepts a project name, `owner/project`, or a GitHub URL. It creates
the GitLab project as `internal`, mirrors branches and tags, and verifies the
result.

`scripts/deploy_gitlab.sh` creates the GitLab OAuth application used by browser
`glab auth login` and writes the returned OAuth `client_id` to the repo-local
glab config at `../.glab-config/glab-cli/config.yml`. The `glab auth login`
command writes the user auth token to that same config directory. The import
script uses the same `XDG_CONFIG_HOME` default, so deploy, auth, and import
read one glab configuration.

#### Git SSH credentials

SSH is the preferred Git transport for local GitLab projects. The local k3d
cluster exposes GitLab Shell on host port `2222`, and the GitLab chart advertises
that port in SSH clone URLs.

Run once per machine/user after `glab auth login` to add your local public key to
GitLab:

```bash
bash scripts/configure_gitlab_ssh_key.sh
```

Use SSH remotes for local GitLab:

```bash
GITLAB_DOMAIN="${GITLAB_DOMAIN:-192.168.86.50.nip.io}"
git remote set-url origin "ssh://git@gitlab.${GITLAB_DOMAIN}:2222/gitlab/project.git"
```

Check SSH access:

```bash
GITLAB_DOMAIN="${GITLAB_DOMAIN:-192.168.86.50.nip.io}"
ssh -T -p 2222 "git@gitlab.${GITLAB_DOMAIN}"
```

The preferred SSH path uses port `2222` because host port `22` normally belongs
to the workstation.

Use environment variables or flags to target another namespace or visibility:

```bash
bash scripts/import_github_project.sh -r emo3/my_repo -g other-group
bash scripts/import_github_project.sh -r emo3/my_repo -v private
```

### Ansible: install kubectl, Helm, glab, helm-git, k3d, and mkcert prerequisites

The playbook `ansible-install-k8s-tools-gitlab-deps.yml` installs Docker, `kubectl`, Helm 4, `glab`, the `helm-git` plugin used by the Garage chart, k3d, and mkcert. It also creates a `gitlab-dev` k3d cluster, switches your kubeconfig to `k3d-gitlab-dev`, and verifies the Kubernetes API with `kubectl get nodes`.

The playbook supports Linux hosts such as AlmaLinux 9 and macOS. On macOS, install Docker Desktop before running the playbook; the playbook starts Docker Desktop when needed and waits for it to become reachable. Docker Engine installation and daemon DNS configuration are Linux-only.

#### AlmaLinux 9 host setup

Install Ansible before running the playbook; the playbook installs the GitLab
runtime dependencies, but not Ansible itself:

```bash
sudo dnf install -y ansible-core
```

Place this repository and the upstream GitLab chart checkout next to each other
on the server, as shown in [Expected Directory Layout](#expected-directory-layout).
Copy `.gitlab.env.example` to `.gitlab.env` and replace all three endpoint
values with the server's stable LAN address (or use the public-domain settings
in [Public HTTPS with Let's Encrypt](README-le.md)). For LAN access, allow the
published GitLab ports through firewalld:

```bash
sudo firewall-cmd --permanent --add-port=80/tcp
sudo firewall-cmd --permanent --add-port=443/tcp
sudo firewall-cmd --permanent --add-port=2222/tcp
sudo firewall-cmd --reload
```

Then run the standard local command from `gitlabc`:

```bash
ansible-playbook -i localhost, --connection=local \
  ansible-install-k8s-tools-gitlab-deps.yml
```

The playbook adds the invoking user to the `docker` group. Sign out and back
in before using Docker directly without `sudo`; cluster creation in the
playbook itself uses a fresh privileged session when necessary.

Starting an existing k3d cluster waits up to two minutes by default. Override the timeout with a Go duration such as `30s`, `5m`, or `1h`:

```bash
ansible-playbook -i localhost, --connection=local \
  -e k3d_cluster_start_timeout=5m \
  ansible-install-k8s-tools-gitlab-deps.yml
```

By default, the playbook also makes Docker's container DNS deterministic by merging this setting into `/etc/docker/daemon.json`:

```json
{
  "dns": ["1.1.1.1", "8.8.8.8"]
}
```

This avoids k3d image pull failures where pods cannot resolve `registry-1.docker.io` from inside the Docker network. Existing Docker daemon settings are preserved, and Docker is restarted only when the daemon config changes. This setting applies to Linux hosts only. To skip this step:

```bash
ansible-playbook -i localhost, --connection=local \
  -e docker_configure_dns=false \
  ansible-install-k8s-tools-gitlab-deps.yml
```

To use different DNS servers:

```bash
ansible-playbook -i localhost, --connection=local \
  -e '{"docker_dns_servers":["192.168.86.1","1.1.1.1"]}' \
  ansible-install-k8s-tools-gitlab-deps.yml
```

#### Run against localhost (inline inventory)

If you saw an error like:

> provided hosts list is empty, only localhost is available

it means your command didn’t provide an inventory that matches the playbook’s `hosts: all`. You can run it locally like this:

```bash
ansible-playbook -i localhost, --connection=local ansible-install-k8s-tools-gitlab-deps.yml
```

#### Run against other hosts (inventory required)

Because the playbook uses `hosts: all`, you must provide an inventory where your target hosts are defined under the `all` group:

```bash
ansible-playbook -i <inventory-file> ansible-install-k8s-tools-gitlab-deps.yml
```

### Container Registry metadata database

New local deployments use the CloudNativePG-backed Container Registry metadata
database. This enables the current Container Registry tag view and related
metadata features.

For an existing local registry that already contains images, migrate it once.
The registry is read-only during the import, so do not push or delete images
until the command completes:

```bash
cd $HOME/code/gitlabc
REGISTRY_METADATA_MIGRATION_CONFIRM=true \
  bash scripts/migrate_registry_metadata_database.sh
```

The workflow runs fully inside the Kubernetes cluster and works the same from
macOS and AlmaLinux hosts, provided the local k3d context and `kubectl` are
available.

The default chart version is controlled by `GITLAB_CHART_VERSION` in `scripts/deploy_gitlab.sh`. Override it when you intentionally want another stable release:

```bash
GITLAB_CHART_VERSION=10.1.1 bash scripts/deploy_gitlab.sh
```

Repeat deploys reconcile the release without restarting GitLab workloads. After
you intentionally replace an external dependency secret, request that restart
explicitly:

```bash
RESTART_GITLAB_WORKLOADS=true bash scripts/deploy_gitlab.sh
```

### Check latest stable versions

Run the stable-version audit to compare the local pins with current upstream
stable releases and verify installed local binaries match the pins:

```bash
bash scripts/check_latest_stable.sh -r
```

Use strict mode for automation. It exits non-zero if a pinned component is no
longer latest stable:

```bash
bash scripts/check_latest_stable.sh -s -r
```

For a daily "latest stable and still healthy" check, combine the audit with the
cluster health check:

```bash
bash scripts/check_latest_stable.sh -s -H -r
```

The audit is read-only by default. `-r` refreshes only local Helm repository
indexes; it never mutates the cluster. Treat
drift as a maintenance signal: GitLab chart patch upgrades can usually be
applied with `scripts/update_gitlab_chart_version.sh -a`, but k3d changes
require a planned cluster rebuild after a backup.

Do not treat the latest K3s node image as automatically safer. Scanner findings
can increase on newer `rancher/k3s` images because the image bundles OS packages
as well as Kubernetes components. The playbook leaves `k3s_image` empty by
default so k3d uses its default supported node image. Pin `k3s_image` only after
your vulnerability scanner approves a candidate:

```bash
ansible-playbook -i localhost, --connection=local \
  -e k3s_image=rancher/k3s:v1.31.5-k3s1 \
  ansible-install-k8s-tools-gitlab-deps.yml
```

To schedule it with cron, create a log directory and add a daily entry:

```bash
mkdir -p .logs
crontab -e
```

Example entry for 6:15 AM every day:

```cron
15 6 * * * cd /Users/emo3/code/gitlabc && bash scripts/check_latest_stable.sh -s -H -r >> .logs/latest-stable.log 2>&1
```

### Update GitLab chart version

Check the latest chart version from the official GitLab Helm repository:

```bash
bash scripts/update_gitlab_chart_version.sh
```

Apply a patch update to the pinned `GITLAB_CHART_VERSION` in
`scripts/deploy_gitlab.sh`, then redeploy:

```bash
bash scripts/update_gitlab_chart_version.sh -a
bash scripts/deploy_gitlab.sh
bash scripts/check_status.sh
```

The updater refuses minor or major jumps unless you explicitly allow them:

```bash
bash scripts/update_gitlab_chart_version.sh -a -m
bash scripts/update_gitlab_chart_version.sh -a -M
```

Use minor or major upgrades deliberately. GitLab chart versions map to GitLab
application versions, but they are not the same version number. For non-patch
upgrades, review the GitLab chart upgrade notes first and avoid skipping required
intermediate releases. Take a GitLab backup before any chart upgrade; persistent
volumes help across restarts, but they are not a rollback plan for failed
migrations or accidental deletes.

### Back up GitLab

Run a backup before chart upgrades, destructive resets, or cluster rebuilds:

```bash
bash scripts/backup_gitlab.sh
```

The helper saves the Rails secrets, runs `backup-utility` in the GitLab toolbox
pod, finds the newest archive in the `gitlab-backups` object-storage bucket,
and copies both restore inputs to `.backups/` on the host. Override the host
directory with `-d`:

```bash
bash scripts/backup_gitlab.sh -d "$HOME/gitlab-backups"
```

The copied archive and Rails secrets are outside the k3d cluster and outside
Garage. Keep at least one known-good backup directory outside this repository
before any major maintenance.

### Move GitLab to another host

To move this deployment (for example, from macOS to an AlmaLinux 9 server), do
not copy k3d or Docker volumes. Create a GitLab backup on the old host, copy
the complete backup directory to the new host, and restore it into a newly
deployed instance running the same GitLab chart/application version.

On the old host:

```bash
mkdir -p "$HOME/gitlab-transfer"
bash scripts/backup_gitlab.sh -d "$HOME/gitlab-transfer"
```

Copy that directory securely to the new host. On the new host, first complete
the AlmaLinux setup above, set `.gitlab.env` for its endpoint, create the k3d
cluster, and deploy GitLab once. Then restore the copied backup directory:

```bash
bash scripts/restore_gitlab.sh -d "$HOME/gitlab-transfer"
bash scripts/check_status.sh
```

The backup directory contains both the GitLab backup archive and Rails secrets;
keep it private. If the hostname changes, redeploy using the new `.gitlab.env`
before restoring, then update Git remotes and reauthenticate `glab` clients.

### Restore GitLab

Restore to the same GitLab chart/application version that created the backup
when possible. The restore process overwrites the freshly deployed GitLab
database and repository data, so only run it against a new or disposable local
instance.

After `reset_local.sh`, redeploy GitLab:

```bash
bash scripts/deploy_gitlab.sh
bash scripts/check_status.sh
```

After `reset_cluster.sh`, recreate the k3d cluster first, then redeploy:

```bash
ansible-playbook -i localhost, --connection=local ansible-install-k8s-tools-gitlab-deps.yml
bash scripts/deploy_gitlab.sh
bash scripts/check_status.sh
```

List the backups available in the default `.backups/` directory:

```bash
bash scripts/restore_gitlab.sh -l
```

Restore the newest backup in `.backups/`:

```bash
bash scripts/restore_gitlab.sh
```

Restore a specific older backup:

```bash
bash scripts/restore_gitlab.sh \
  -f .backups/1783202695_2026_07_04_19.1.1-ee_gitlab_backup.tar
```

Restore from a backup directory outside the repository:

```bash
bash scripts/restore_gitlab.sh -d "$HOME/gitlab-backups"
```

The restore helper replaces the Rails secrets, restarts GitLab pods, copies the
selected archive into the toolbox pod, scales `sidekiq` and `webservice` down,
runs `backup-utility --restore` with `GITLAB_ASSUME_YES=1`, scales them back up,
and waits for status.

## Reset and Start Over

### Durable state

The running local instance keeps durable state in Kubernetes PVCs backed by k3d
Docker volumes:

- Gitaly stores Git repository data.
- CloudNativePG/PostgreSQL stores GitLab application data.
- Garage stores object data such as uploads, artifacts, packages, LFS objects,
  registry data, and backup archives.

`k3d cluster stop gitlab-dev` preserves that state. The reset scripts remove the
GitLab namespace and dependency releases, so treat them as data-destructive even
when the k3d cluster itself remains.

To stop the local environment without deleting data, stop the k3d cluster:

```bash
bash "$HOME/code/gitlabc/scripts/stop_gitlab.sh"
```

Start it again with:

```bash
bash "$HOME/code/gitlabc/scripts/start_gitlab.sh"
```

Reset GitLab and the external dependencies, but keep the k3d cluster:

```bash
bash scripts/reset_local.sh
```

Use this when you are debugging GitLab chart values or dependency state. It is faster and preserves the cluster itself. The reset scripts default to Kubernetes context `k3d-gitlab-dev`; override with `KUBE_CONTEXT=...` if needed.

Reset everything, including the k3d cluster:

```bash
bash scripts/reset_cluster.sh
```

Use this when you want to validate the whole setup from zero, or when cluster-level resources such as CRDs, admission webhooks, ingress controllers, or Gateway API state may be stale. It is slower because the cluster and images have to be recreated.

By default, `reset_cluster.sh` also runs:

```bash
docker system prune -a --volumes -f
docker volume prune -a -f
docker buildx history rm --all
docker system df
```

This removes unused Docker images, volumes, networks, and build cache after the k3d cluster is deleted, then prints Docker disk usage. To skip Docker pruning:

```bash
PRUNE_DOCKER=false bash scripts/reset_cluster.sh
```

After `reset_cluster.sh`, recreate the cluster and deploy:

```bash
ansible-playbook -i localhost, --connection=local ansible-install-k8s-tools-gitlab-deps.yml
bash scripts/dev_dependencies.sh setup
bash scripts/deploy_gitlab.sh
```

## Check that it is healthy

Wait up to ten minutes and print focused diagnostics if anything is stuck:

```bash
bash scripts/check_status.sh
```

You can change the timeout:

```bash
TIMEOUT_SECONDS=660 bash scripts/check_status.sh
```

```bash
kubectl get pods -n gitlab --watch
# Press Ctrl+C to stop.
```

```bash
# Helm Status
helm status gitlab -n gitlab
# All Resources Overview
kubectl get all -n gitlab
```

### Check Specific Components

```bash
# Check migrations job (very important — must complete)
kubectl get jobs -n gitlab

# Check Ingress
kubectl get ingress -n gitlab

# Check Services (especially the main one)
kubectl get svc -n gitlab
```

### View Logs (when a pod is stuck)

```bash
# List pods first
kubectl get pods -n gitlab

# Follow logs of a specific pod (replace <pod-name>)
kubectl logs -f -n gitlab <pod-name>

# Example for webservice
kubectl logs -f -n gitlab gitlab-webservice-xxx
```

## Login

The initial administrator username is:

```text
root
```

Get the initial root password:

```bash
kubectl get secret -n gitlab gitlab-gitlab-initial-root-password \
  -o go-template='{{index .data "password" | base64decode}}{{"\n"}}'
```

After restoring from a backup, that Kubernetes secret may no longer match the
restored GitLab database. Reset `root` through the toolbox pod instead:

```bash
bash scripts/create_user.sh \
  -u root \
  -e root@example.com \
  -n "Administrator" \
  -p 'TempPassword123!' \
  -a \
  -U
```

Create a user without relying on outbound email:

```bash
bash scripts/create_user.sh \
  -u alice \
  -e alice@example.com \
  -n "Alice Example"
```

The script runs through the GitLab toolbox pod with `gitlab-rails runner`, so it
uses GitLab's Rails models instead of writing directly to PostgreSQL tables. It
generates and prints an 8-character password when `-p` is not provided. Add
`-p 'TempPassword123!'` when you want to set a specific password.

Reset an existing user's password:

```bash
bash scripts/create_user.sh \
  -u alice \
  -e alice@example.com \
  -n "Alice Example" \
  -U
```

## Cleanup

Prefer the reset scripts instead of broad Docker cleanup commands:

```bash
bash scripts/reset_local.sh
```

For a full cluster reset:

```bash
bash scripts/reset_cluster.sh
```

This also prunes unused Docker images/cache/volumes by default. Avoid separate commands such as `docker rm -f $(docker ps -aq)` unless you intentionally want to remove unrelated running containers on the host.
