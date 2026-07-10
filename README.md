# Local GitLab chart notes

Use this profile for local development with k3d. It runs GitLab through the
bundled nginx ingress with mkcert-trusted HTTPS by default. Let's Encrypt is
available as an optional public HTTPS profile.

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

- `ansible-install-k8s-tools-gitlab-deps.yml` — installs Docker, `kubectl`, Helm 4, the `helm-git` plugin, k3d, and mkcert; creates the `gitlab-dev` cluster; switches kubeconfig to `k3d-gitlab-dev`; and verifies Kubernetes is reachable.

## Quick start

Run this from the `gitlabc` directory:

```bash
cd $HOME/code/gitlabc
ansible-playbook -i localhost, --connection=local --ask-become-pass ansible-install-k8s-tools-gitlab-deps.yml
bash scripts/deploy_gitlab.sh
bash scripts/check_status.sh
```

The Ansible playbook bootstraps local tools and the k3d cluster. The deploy
script then idempotently sets up external dependencies, validates generated
secrets, creates the local mkcert TLS secret, deploys GitLab, and disables
public sign-ups.

Garage object storage is installed with Kubernetes PVC persistence enabled by
default. The default Garage PVC sizes are `1Gi` for metadata and `10Gi` for
data; override them with `GARAGE_META_PERSISTENCE_SIZE` and
`GARAGE_DATA_PERSISTENCE_SIZE` before dependency setup. For disposable test
runs only, set `GARAGE_PERSISTENCE_ENABLED=false`. This default applies to new
Garage installs; an existing Garage release created without persistence must be
reinstalled or upgraded explicitly before it has persistent object storage.

Open the local mkcert HTTPS URL:

```text
https://gitlab.127.0.0.1.nip.io/users/sign_in
```

### Common operations

| Task | Command |
| --- | --- |
| Check health | `bash scripts/check_status.sh` |
| Configure k3d registry pulls | `bash scripts/configure_k3d_registry_pull.sh` |
| Stop without deleting data | `k3d cluster stop gitlab-dev` |
| Start again | `k3d cluster start gitlab-dev && bash scripts/check_status.sh` |
| Back up GitLab | `bash scripts/backup_gitlab.sh` |
| Restore GitLab | `bash scripts/restore_gitlab.sh -l` then `bash scripts/restore_gitlab.sh` |
| Import a GitHub project | `bash scripts/import_github_project.sh -r emo3/my_repo` |
| Create a local user | `bash scripts/create_user.sh -u alice -e alice@example.com -n "Alice Example"` |
| Destructive local reset | `bash scripts/reset_local.sh` |

`configure_k3d_registry_pull.sh` is for the standalone Kubernetes runner. It
lets k3d nodes pull `registry.127.0.0.1.nip.io` images directly through the
local GitLab HTTPS ingress.

### Import GitHub projects

After GitLab is deployed, authenticate `glab` against the local GitLab host
using the repo-local config directory:

```bash
XDG_CONFIG_HOME=../.glab-config glab auth login \
  --hostname gitlab.127.0.0.1.nip.io \
  --api-host gitlab.127.0.0.1.nip.io \
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
git remote set-url origin ssh://git@gitlab.127.0.0.1.nip.io:2222/gitlab/project.git
```

Check SSH access:

```bash
ssh -T -p 2222 git@gitlab.127.0.0.1.nip.io
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

Starting an existing k3d cluster waits up to two minutes by default. Override the timeout with a Go duration such as `30s`, `5m`, or `1h`:

```bash
ansible-playbook -i localhost, --connection=local --ask-become-pass \
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
ansible-playbook -i localhost, --connection=local --ask-become-pass \
  -e docker_configure_dns=false \
  ansible-install-k8s-tools-gitlab-deps.yml
```

To use different DNS servers:

```bash
ansible-playbook -i localhost, --connection=local --ask-become-pass \
  -e '{"docker_dns_servers":["192.168.86.1","1.1.1.1"]}' \
  ansible-install-k8s-tools-gitlab-deps.yml
```

#### Run against localhost (inline inventory)

If you saw an error like:

> provided hosts list is empty, only localhost is available

it means your command didn’t provide an inventory that matches the playbook’s `hosts: all`. You can run it locally like this:

```bash
ansible-playbook -i localhost, --connection=local --ask-become-pass ansible-install-k8s-tools-gitlab-deps.yml
```

#### Run against other hosts (inventory required)

Because the playbook uses `hosts: all`, you must provide an inventory where your target hosts are defined under the `all` group:

```bash
ansible-playbook -i <inventory-file> ansible-install-k8s-tools-gitlab-deps.yml
```

### Local HTTPS with mkcert

The default deploy profile is `local-mkcert`. It uses a locally trusted mkcert
certificate stored in Kubernetes secret `gitlab-local-tls`.

Deploy GitLab with mkcert HTTPS:

```bash
bash scripts/deploy_gitlab.sh
bash scripts/check_status.sh
```

This is equivalent to `GITLAB_DEPLOY_PROFILE=local-mkcert bash scripts/deploy_gitlab.sh`.

The helper installs the mkcert local CA if needed, writes certificate files under
`.certs/`, and applies a Kubernetes TLS secret named `gitlab-local-tls` in the
GitLab namespace. The generated certificate covers the default GitLab host, the
wildcard domain, the base domain, `localhost`, and `127.0.0.1`.

If you change the domain or namespace, pass the same values to both commands:

```bash
GITLAB_DOMAIN=gitlab.localtest.me NAMESPACE=my-gitlab bash scripts/create_mkcert.sh
GITLAB_DOMAIN=gitlab.localtest.me NAMESPACE=my-gitlab \
  GITLAB_DEPLOY_PROFILE=local-mkcert \
  bash scripts/deploy_gitlab.sh
```

Regenerate the certificate when the hostnames it covers change:

```bash
FORCE_REGENERATE_CERT=true bash scripts/create_mkcert.sh
```

### Optional Public Let's Encrypt

The public Let's Encrypt profile serves GitLab at:

```text
https://gitlab.edmo3.dynv6.net/users/sign_in
```

Deploy it with:

```bash
GITLAB_DEPLOY_PROFILE=public-letsencrypt bash scripts/deploy_gitlab.sh
bash scripts/check_status.sh
```

The deploy script sets up dependencies by default, then composes the generated
dependency values at `.values/dev-external.values.yaml` with
`public-letsencrypt.values.yaml`. The public values file enables HTTPS, GitLab
ingress, chart-managed cert-manager, the GitLab ACME issuer, and the bundled
nginx ingress controller.

Before deploying, make sure all public prerequisites are true:

- `gitlab.edmo3.dynv6.net` resolves to your current public IP.
- The router forwards public TCP ports 80 and 443 to this host.
- The host firewall allows TCP ports 80 and 443.
- The k3d cluster was created with `80:80@loadbalancer` and
  `443:443@loadbalancer` port mappings.

Public access depends on your network. In prior testing, local access and the
Let's Encrypt certificate worked, external access through alternate port `8443`
worked, and plain external `443` still depended on router or ISP behavior.

After deploying, check certificate progress:

```bash
kubectl get issuer,certificate,challenge,order -n gitlab
kubectl get ingress -n gitlab
curl -I https://gitlab.edmo3.dynv6.net/users/sign_in
```

The deploy helper disables the Web IDE single-origin fallback warning by setting
`vscode_extension_marketplace_single_origin_fallback_enabled=false` for both
local and public profiles. By default it keeps GitLab's upstream extension host domain,
`cdn.web-ide.gitlab-static.net`. To use a custom host, provide a wildcard DNS
and TLS setup first, then deploy with:

```bash
PUBLIC_WEB_IDE_EXTENSION_HOST_DOMAIN=webide.edmo3.dynv6.net \
  GITLAB_DEPLOY_PROFILE=public-letsencrypt \
  bash scripts/deploy_gitlab.sh
```

The default chart version is controlled by `GITLAB_CHART_VERSION` in `scripts/deploy_gitlab.sh`. Override it when you intentionally want another stable release:

```bash
GITLAB_CHART_VERSION=10.1.1 bash scripts/deploy_gitlab.sh
```

### Check latest stable versions

Run the stable-version audit to compare the local pins with current upstream
stable releases and verify installed local binaries match the pins:

```bash
bash scripts/check_latest_stable.sh
```

Use strict mode for automation. It exits non-zero if a pinned component is no
longer latest stable:

```bash
bash scripts/check_latest_stable.sh -s
```

For a daily "latest stable and still healthy" check, combine the audit with the
cluster health check:

```bash
bash scripts/check_latest_stable.sh -s -H
```

That command is safe to run daily because it does not mutate the cluster. Treat
drift as a maintenance signal: GitLab chart patch upgrades can usually be
applied with `scripts/update_gitlab_chart_version.sh -a`, but k3d changes
require a planned cluster rebuild after a backup.

Do not treat the latest K3s node image as automatically safer. Scanner findings
can increase on newer `rancher/k3s` images because the image bundles OS packages
as well as Kubernetes components. The playbook leaves `k3s_image` empty by
default so k3d uses its default supported node image. Pin `k3s_image` only after
your vulnerability scanner approves a candidate:

```bash
ansible-playbook -i localhost, --connection=local --ask-become-pass \
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
15 6 * * * cd /Users/emo3/code/gitlabc && bash scripts/check_latest_stable.sh -s -H >> .logs/latest-stable.log 2>&1
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
ansible-playbook -i localhost, --connection=local --ask-become-pass ansible-install-k8s-tools-gitlab-deps.yml
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

## Networking & Dynamic DNS Validation

This section is an example public setup for `gitlab.edmo3.dynv6.net`. The
default local mkcert profile does not require DDNS, public port forwarding, or
firewall changes.

For public Let's Encrypt validation, public internet traffic on TCP ports 80
and 443 must reach the host machine, then the k3d load balancer, then the
bundled nginx ingress controller.

### Dynamic DNS (DDNS) Automation via ddclient

To automatically track and update public IP alterations with `dynv6`, `ddclient` was pulled from the EPEL repository and configured to use external web-based IP detection rather than reporting local interface configurations.

File modified: `/etc/ddclient.conf`

```text
use=web, web=checkip.dyndns.org
protocol=dyndns2
server=dynv6.com
login=none
password=<HIDDEN_TOKEN>
edmo3.dynv6.net
```

#### Service Persistence

```bash
sudo rm -f /var/cache/ddclient/ddclient.cache
sudo systemctl enable --now ddclient
```

### Open firewall

By default, AlmaLinux 9 ships with firewalld, which drops unexpected ingress
traffic unless you explicitly allow it.

```bash
sudo firewall-cmd --permanent --add-port=80/tcp
sudo firewall-cmd --permanent --add-port=443/tcp
sudo firewall-cmd --reload
```

#### Edge Network Port Forwarding

Within the Wi-Fi router gateway configuration layer (192.168.86.1), configure
static WAN-to-LAN mapping rules:

```text
External port 80 TCP  -> internal port 80 on 192.168.86.141
External port 443 TCP -> internal port 443 on 192.168.86.141
```

## Local Scripts

| Script | Purpose |
| --- | --- |
| `bash scripts/dev_dependencies.sh setup` | Deploys Valkey, CloudNativePG/PostgreSQL, and Garage with PVC persistence enabled, then writes `.values/dev-external.values.yaml`. |
| `bash scripts/dev_dependencies.sh status` | Shows the status of the external dependencies. |
| `bash scripts/dev_dependencies.sh teardown` | Removes the external dependencies without removing the GitLab release. |
| `bash scripts/create_mkcert.sh` | Generates a local mkcert wildcard certificate and applies it as a Kubernetes TLS secret for trusted local HTTPS. |
| `bash scripts/check_latest_stable.sh` | Checks pinned local tool and chart versions against current upstream stable releases. |
| `bash scripts/update_gitlab_chart_version.sh` | Checks the latest GitLab Helm chart and optionally updates the pinned chart version in `scripts/deploy_gitlab.sh`. |
| `bash scripts/deploy_gitlab.sh` | Installs the pinned stable `gitlab/gitlab` chart release and deploys GitLab through nginx ingress. |
| `bash scripts/check_status.sh` | Waits up to ten minutes for GitLab to become healthy. If it times out, it prints stuck pods, recent events, pod descriptions, and recent logs. |
| `bash scripts/backup_gitlab.sh` | Runs a toolbox backup and copies the newest backup archive to `.backups/` on the host. |
| `bash scripts/restore_gitlab.sh` | Restores a selected GitLab backup archive from `.backups/` or another backup directory. |
| `bash scripts/reset_local.sh` | Destructive: removes GitLab, external dependencies, the `gitlab` namespace, and local generated files, but keeps the k3d cluster. |
| `bash scripts/reset_cluster.sh` | Destructive: runs the local reset, deletes the `gitlab-dev` k3d cluster, and prunes unused Docker images/cache/volumes. |

Use a longer health-check timeout when needed:

```bash
TIMEOUT_SECONDS=660 bash scripts/check_status.sh
```

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
k3d cluster stop gitlab-dev
```

Start it again with:

```bash
k3d cluster start gitlab-dev
bash scripts/check_status.sh
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
ansible-playbook -i localhost, --connection=local --ask-become-pass ansible-install-k8s-tools-gitlab-deps.yml
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

## Current access path

Use nginx ingress on host port 443. Do not use `kubectl port-forward` or
`:8080` for browser access.

For the default local mkcert profile:

```bash
curl -I https://gitlab.127.0.0.1.nip.io/users/sign_in
```

For the optional public Let's Encrypt profile:

```bash
curl -I https://gitlab.edmo3.dynv6.net/users/sign_in
```

Then open the URL for the profile you deployed:

- mkcert local HTTPS: `https://gitlab.127.0.0.1.nip.io/users/sign_in`
- Let's Encrypt public HTTPS: `https://gitlab.edmo3.dynv6.net/users/sign_in`

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
