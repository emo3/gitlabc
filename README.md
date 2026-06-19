# Local GitLab chart notes

Use this profile for local development with k3d. It runs GitLab over HTTP on localhost.

## Pull the GitLab Helm chart code

```bash
cd $HOME/code
git clone https://gitlab.com/gitlab-org/charts/gitlab.git gitlabc
cd gitlabc
```

## Ansible playbooks overview

- `ansible-install-k8s-tools-gitlab-deps.yml` — installs Docker, `kubectl`, Helm, and k3d; creates the `gitlab-dev` cluster; switches kubeconfig to `k3d-gitlab-dev`; and verifies Kubernetes is reachable.

## Quick start

Run this from the `gitlabc` directory:

```bash
ansible-playbook -i localhost, --connection=local --ask-become-pass ansible-install-k8s-tools-gitlab-deps.yml
kubectl config use-context k3d-gitlab-dev
kubectl get nodes
bash scripts/dev_dependencies.sh setup
```

### Ansible: install kubectl, Helm, and k3d prerequisites

The playbook `ansible-install-k8s-tools-gitlab-deps.yml` installs Docker, `kubectl`, Helm, and k3d. It also creates a `gitlab-dev` k3d cluster, switches your kubeconfig to `k3d-gitlab-dev`, and verifies the Kubernetes API with `kubectl get nodes`.

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

### Deploy GitLab using the generated values

```bash
helm dependency update
helm upgrade --install gitlab . \
  --namespace gitlab \
  --timeout 600s \
  -f .values/dev-external.values.yaml \
  --set global.hosts.domain=127.0.0.1.nip.io \
  --set global.hosts.externalIP=127.0.0.1 \
  --set certmanager-issuer.email=infuse.1301@gmail.com \
  --set global.hosts.https=false \
  --set gatewayApiResources.gateway.protocol=HTTP \
  --set gatewayApiResources.envoy.clientTrafficPolicySpec.path.escapedSlashesAction=KeepUnchanged \
  --set global.gatewayApi.configureCertmanager=false \
  --set global.gatewayApi.httpToHttpsRedirect=false \
  --set gitlab-runner.install=false \
  --set prometheus.install=false
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
