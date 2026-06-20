# Local GitLab chart notes

Use this profile for local development with k3d. It runs GitLab over HTTP on localhost.

## Pull the GitLab Helm chart code

```bash
cd $HOME/code
git clone https://gitlab.com/gitlab-org/charts/gitlab.git
# make it ReadOnly
chmod -R a-w gitlab
```

## Ansible playbooks overview

- `ansible-install-k8s-tools-gitlab-deps.yml` — installs Docker, `kubectl`, Helm, and k3d; creates the `gitlab-dev` cluster; switches kubeconfig to `k3d-gitlab-dev`; and verifies Kubernetes is reachable.

## Quick start

Run this from the `gitlabc` directory:

```bash
cd $HOME/code/gitlabc
ansible-playbook -i localhost, --connection=local --ask-become-pass ansible-install-k8s-tools-gitlab-deps.yml
kubectl config use-context k3d-gitlab-dev
kubectl get nodes
bash scripts/dev_dependencies.sh setup
bash scripts/deploy_gitlab.sh
```

### Ansible: install kubectl, Helm, and k3d prerequisites

The playbook `ansible-install-k8s-tools-gitlab-deps.yml` installs Docker, `kubectl`, Helm, and k3d. It also creates a `gitlab-dev` k3d cluster, switches your kubeconfig to `k3d-gitlab-dev`, and verifies the Kubernetes API with `kubectl get nodes`.

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

If `kubectl` still points at minikube and fails with `192.168.49.2:8443`, rerun the playbook or switch contexts manually:

```bash
kubectl config get-contexts
kubectl config use-context k3d-gitlab-dev
```

## Run the setup script (it provisions everything locally in your cluster)

```bash
# Default namespace is 'gitlab'
bash scripts/dev_dependencies.sh setup
# Or with custom namespace:
# NAMESPACE=my-gitlab bash scripts/dev_dependencies.sh setup
```

The local wrapper reuses the helper libraries from `../gitlab`, but writes generated values to this repository at `.values/dev-external.values.yaml`. This keeps the upstream chart checkout clean.

### Deploy GitLab from gitlabc

Deploy GitLab over HTTP through the bundled nginx ingress. The deploy script builds an ignored local chart mirror at `.chart/gitlab`, so Helm dependency archives do not modify `../gitlab`.

```bash
bash scripts/deploy_gitlab.sh
```

Do not run `helm dependency update ../gitlab` from this profile unless you intend to modify the upstream checkout. Use `scripts/deploy_gitlab.sh`, which updates `.chart/gitlab` instead.

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

After `reset_cluster.sh`, recreate the cluster and deploy:

```bash
ansible-playbook -i localhost, --connection=local --ask-become-pass ansible-install-k8s-tools-gitlab-deps.yml
bash scripts/dev_dependencies.sh setup
bash scripts/deploy_gitlab.sh
```

## Check that it is healthy

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

## dev_dependencies.sh Helper (if you used the script)

`bash scripts/dev_dependencies.sh status`

## Current access path

Use nginx ingress on host port 80. Do not use `kubectl port-forward` or `:8080` for browser access.

```bash
curl http://gitlab.127.0.0.1.nip.io/users/sign_in
```

Then open:

```text
http://gitlab.127.0.0.1.nip.io/users/sign_in
```

## clean up stuff

### See what will be deleted

```bash
docker ps -a
docker volume ls
docker images
```

### Stop and remove everything

```bash
docker stop $(docker ps -aq)
docker rm -f $(docker ps -aq)
```

### Remove all images

`docker rmi -f $(docker images -aq)`

### Remove all volumes

`docker volume rm $(docker volume ls -q)`

### Remove unused networks

```bash
docker network prune -f
# Or do it all at once
docker system prune -a --volumes -f
# Then verify
docker system df
```

### You should see something close to

```text
Images          0
Containers      0
Local Volumes   0
Build Cache     0
```

### If you're also trying to start clean with GitLab on Kubernetes

```bash
# Docker cleanup is not enough. You should also remove the Helm release and namespace.
helm uninstall gitlab -n gitlab
kubectl delete namespace gitlab
# Then verify
helm list -A
kubectl get ns
```

### Remove the k3d cluster

```bash
k3d cluster delete gitlab-dev
```
