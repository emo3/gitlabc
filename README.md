# Local GitLab chart notes

Use this profile for local development with k3d. It runs GitLab on localhost through
the bundled nginx ingress, with HTTP by default and optional HTTPS.

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
kubectl config use-context k3d-gitlab-dev
kubectl get nodes
bash scripts/dev_dependencies.sh setup
bash scripts/deploy_gitlab.sh
bash scripts/check_status.sh
```

For public HTTPS with Let's Encrypt:

```bash
cd $HOME/code/gitlabc
ansible-playbook -i localhost, --connection=local --ask-become-pass ansible-install-k8s-tools-gitlab-deps.yml
kubectl config use-context k3d-gitlab-dev
bash scripts/dev_dependencies.sh setup
GITLAB_DEPLOY_PROFILE=public-letsencrypt bash scripts/deploy_gitlab.sh
bash scripts/check_status.sh
```

### Ansible: install kubectl, Helm, helm-git, k3d, and mkcert prerequisites

The playbook `ansible-install-k8s-tools-gitlab-deps.yml` installs Docker, `kubectl`, Helm 4, the `helm-git` plugin used by the Garage chart, k3d, and mkcert. It also creates a `gitlab-dev` k3d cluster, switches your kubeconfig to `k3d-gitlab-dev`, and verifies the Kubernetes API with `kubectl get nodes`.

By default, the playbook also makes Docker's container DNS deterministic by merging this setting into `/etc/docker/daemon.json`:

```json
{
  "dns": ["1.1.1.1", "8.8.8.8"]
}
```

This avoids k3d image pull failures where pods cannot resolve `registry-1.docker.io` from inside the Docker network. Existing Docker daemon settings are preserved, and Docker is restarted only when the daemon config changes. To skip this step:

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

### Public Let's Encrypt over HTTP-01

The public Let's Encrypt profile serves GitLab at:

```text
https://gitlab.edmo3.dynv6.net/users/sign_in
```

Deploy it with:

```bash
bash scripts/dev_dependencies.sh setup
GITLAB_DEPLOY_PROFILE=public-letsencrypt bash scripts/deploy_gitlab.sh
bash scripts/check_status.sh
```

This profile composes the generated dependency values at
`.values/dev-external.values.yaml` with `public-letsencrypt.values.yaml`. The
public values file enables HTTPS, GitLab ingress, chart-managed cert-manager,
the GitLab ACME issuer, and the bundled nginx ingress controller.

Before deploying, make sure all public HTTP-01 prerequisites are true:

- `gitlab.edmo3.dynv6.net` resolves to your current public IP.
- The router forwards public TCP ports 80 and 443 to this host.
- The host firewall allows TCP ports 80 and 443.
- The k3d cluster was created with `80:80@loadbalancer` and
  `443:443@loadbalancer` port mappings.

After deploying, check certificate progress:

```bash
kubectl get issuer,certificate,challenge,order -n gitlab
kubectl get ingress -n gitlab
curl -I http://gitlab.edmo3.dynv6.net
curl -I https://gitlab.edmo3.dynv6.net/users/sign_in
```

The default chart version is controlled by `GITLAB_CHART_VERSION` in `scripts/deploy_gitlab.sh`. Override it when you intentionally want another stable release:

```bash
GITLAB_CHART_VERSION=10.1.1 bash scripts/deploy_gitlab.sh
```

### Update GitLab chart version

Check the latest chart version from the official GitLab Helm repository:

```bash
bash scripts/update_gitlab_chart_version.sh
```

Apply a patch update to the pinned `GITLAB_CHART_VERSION` in
`scripts/deploy_gitlab.sh`, then redeploy:

```bash
bash scripts/update_gitlab_chart_version.sh --apply
GITLAB_DEPLOY_PROFILE=public-letsencrypt bash scripts/deploy_gitlab.sh
bash scripts/check_status.sh
```

The updater refuses minor or major jumps unless you explicitly allow them:

```bash
bash scripts/update_gitlab_chart_version.sh --apply --allow-minor
bash scripts/update_gitlab_chart_version.sh --apply --allow-major
```

Use minor or major upgrades deliberately. GitLab chart versions map to GitLab
application versions, but they are not the same version number. For non-patch
upgrades, review the GitLab chart upgrade notes first and avoid skipping required
intermediate releases.

## Networking & Dynamic DNS Validation

For public Let's Encrypt validation with HTTP-01, public internet traffic on
standard HTTP and HTTPS ports must reach the host machine, then the k3d load
balancer, then the bundled nginx ingress controller.

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
sudo firewall-cmd --permanent --add-service=http
sudo firewall-cmd --permanent --add-service=https
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
| `bash scripts/dev_dependencies.sh setup` | Deploys Valkey, CloudNativePG/PostgreSQL, and Garage, then writes `.values/dev-external.values.yaml`. |
| `bash scripts/dev_dependencies.sh status` | Shows the status of the external dependencies. |
| `bash scripts/dev_dependencies.sh teardown` | Removes the external dependencies without removing the GitLab release. |
| `bash scripts/create_mkcert.sh` | Generates a local mkcert wildcard certificate and applies it as a Kubernetes TLS secret for trusted local HTTPS. |
| `bash scripts/update_gitlab_chart_version.sh` | Checks the latest GitLab Helm chart and optionally updates the pinned chart version in `scripts/deploy_gitlab.sh`. |
| `bash scripts/deploy_gitlab.sh` | Installs the pinned stable `gitlab/gitlab` chart release and deploys GitLab through nginx ingress. |
| `bash scripts/check_status.sh` | Waits up to ten minutes for GitLab to become healthy. If it times out, it prints stuck pods, recent events, pod descriptions, and recent logs. |
| `bash scripts/reset_local.sh` | Removes GitLab, external dependencies, the `gitlab` namespace, and local generated files, but keeps the k3d cluster. |
| `bash scripts/reset_cluster.sh` | Runs the local reset, deletes the `gitlab-dev` k3d cluster, and prunes unused Docker images/cache/volumes. |

Use a longer health-check timeout when needed:

```bash
TIMEOUT_SECONDS=660 bash scripts/check_status.sh
```

## Reset and Start Over

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

Use nginx ingress on host port 80 for HTTP or host port 443 for HTTPS. Do not
use `kubectl port-forward` or `:8080` for browser access.

For the public Let's Encrypt profile:

```bash
curl -I http://gitlab.edmo3.dynv6.net
curl -I https://gitlab.edmo3.dynv6.net/users/sign_in
```

For the default local HTTP profile:

```bash
curl http://gitlab.127.0.0.1.nip.io/users/sign_in
```

Then open the URL for the profile you deployed:

```text
https://gitlab.edmo3.dynv6.net/users/sign_in
http://gitlab.127.0.0.1.nip.io/users/sign_in
```

## Login

The initial administrator username is:

```text
root
```

Get the initial root password:

```bash
kubectl get secret -n gitlab gitlab-gitlab-initial-root-password -o jsonpath='{.data.password}' | base64 -d; echo
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
