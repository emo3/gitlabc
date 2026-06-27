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

For trusted local HTTPS with mkcert, create the TLS secret before deploying
GitLab:

```bash
cd $HOME/code/gitlabc
ansible-playbook -i localhost, --connection=local --ask-become-pass ansible-install-k8s-tools-gitlab-deps.yml
kubectl config use-context k3d-gitlab-dev
bash scripts/dev_dependencies.sh setup
bash scripts/create_mkcert.sh
GITLAB_HTTPS=true GITLAB_TLS_SECRET=gitlab-local-tls bash scripts/deploy_gitlab.sh
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

## Verify the local k3d cluster

The Ansible playbook creates the cluster for you. Verify your shell is pointed at it before running the GitLab dependency setup script:

```bash
kubectl config use-context k3d-gitlab-dev
kubectl get nodes
```

This profile uses k3d only.

The setup assumes the k3d cluster created by this playbook:

- kube context: `k3d-gitlab-dev`
- cluster name: `gitlab-dev`
- Docker-backed k3d nodes
- host port mappings for local HTTP and HTTPS traffic
- nginx ingress reachable through the k3d load balancer
- local image/DNS behavior from Docker

```bash
kubectl config current-context
```

Expected output:

```text
k3d-gitlab-dev
```

If needed, switch back:

```bash
kubectl config use-context k3d-gitlab-dev
```

If you intentionally deleted the k3d cluster, reset `~/.kube/config` and rerun the Ansible playbook to recreate the k3d context.

## Run the setup script (it provisions everything locally in your cluster)

```bash
# Default namespace is 'gitlab'
bash scripts/dev_dependencies.sh setup
# Or with custom namespace:
# NAMESPACE=my-gitlab bash scripts/dev_dependencies.sh setup
```

The local wrapper reuses helper libraries from `../gitlab`, but writes generated values to this repository at `.values/dev-external.values.yaml`. This keeps the upstream chart checkout clean. The GitLab deploy itself uses the released `gitlab/gitlab` chart from the official Helm repo.

### Deploy GitLab from gitlabc

Deploy GitLab over HTTP through the bundled nginx ingress. The deploy script installs a pinned stable chart release from the official GitLab Helm repository.

```bash
bash scripts/deploy_gitlab.sh
```

To deploy over HTTPS locally, enable HTTPS for the chart:

```bash
GITLAB_HTTPS=true bash scripts/deploy_gitlab.sh
```

The k3d cluster created by the Ansible playbook already exposes host port 443.
For the default local `127.0.0.1.nip.io` domain, the chart generates a
self-signed wildcard certificate, so your browser will show a certificate warning
unless you trust that certificate locally.

### HTTPS options

For local development, use mkcert when you want browser-trusted HTTPS without a
public domain:

```bash
bash scripts/create_mkcert.sh
GITLAB_HTTPS=true GITLAB_TLS_SECRET=gitlab-local-tls bash scripts/deploy_gitlab.sh
```

The helper installs the mkcert local CA if needed, writes the generated
certificate files under `.certs/`, and creates a Kubernetes TLS secret named
`gitlab-local-tls` in the GitLab namespace. The generated certificate includes
the default GitLab host, the wildcard domain, the base domain, `localhost`, and
`127.0.0.1`. The helper is idempotent: when both certificate files already
exist, it reuses them and reapplies the Kubernetes TLS secret.

If you use a different domain or namespace, pass the same environment values to
both commands:

```bash
GITLAB_DOMAIN=gitlab.localtest.me NAMESPACE=my-gitlab bash scripts/create_mkcert.sh
GITLAB_DOMAIN=gitlab.localtest.me NAMESPACE=my-gitlab \
  GITLAB_HTTPS=true GITLAB_TLS_SECRET=gitlab-local-tls \
  bash scripts/deploy_gitlab.sh
```

The hostname you open in your browser must be covered by the mkcert certificate
SANs. If you change `GITLAB_DOMAIN`, regenerate and reapply the TLS secret.

```bash
FORCE_REGENERATE_CERT=true bash scripts/create_mkcert.sh
```

Use the chart-generated self-signed certificate when you only need HTTPS
transport and do not mind browser or Git client trust warnings:

```bash
GITLAB_HTTPS=true bash scripts/deploy_gitlab.sh
```

Use Let's Encrypt only when GitLab has a real DNS name. For a local k3d cluster,
DNS-01 is usually the practical route because HTTP-01 requires public inbound
access to the ingress controller. This profile does not install cert-manager or
DNS provider credentials for Let's Encrypt.

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
GITLAB_HTTPS=true GITLAB_TLS_SECRET=gitlab-local-tls bash scripts/deploy_gitlab.sh
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

Use nginx ingress on host port 80 for HTTP or host port 443 for HTTPS. Do not use
`kubectl port-forward` or `:8080` for browser access.

```bash
curl http://gitlab.127.0.0.1.nip.io/users/sign_in
```

For HTTPS:

```bash
curl -k https://gitlab.127.0.0.1.nip.io/users/sign_in
```

If you deployed with `scripts/create_mkcert.sh` and the mkcert root CA
is trusted on this machine, you can omit `-k`:

```bash
curl https://gitlab.127.0.0.1.nip.io/users/sign_in
```

Then open one of these, depending on how you deployed:

```text
http://gitlab.127.0.0.1.nip.io/users/sign_in
https://gitlab.127.0.0.1.nip.io/users/sign_in
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
