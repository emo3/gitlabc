# Local HTTPS with mkcert

Use this guide for the default `local-mkcert` deployment profile. It is the
right choice for a development workstation or a trusted LAN; it does not need
public DNS, router port forwarding, or a public certificate authority.

For shared setup, maintenance, backup and restore instructions, see
[README.md](README.md).

## Deploy on the GitLab host

From the `gitlabc` directory, create or reconcile the local cluster and deploy
GitLab:

```bash
ansible-playbook -i localhost, --connection=local \
  ansible-install-k8s-tools-gitlab-deps.yml
bash scripts/deploy_gitlab.sh
bash scripts/check_status.sh
```

`deploy_gitlab.sh` defaults to `GITLAB_DEPLOY_PROFILE=local-mkcert`. It creates
or reuses the `gitlab-local-tls` Kubernetes secret and deploys GitLab through
the bundled nginx ingress.

Open:

```text
https://gitlab.192.168.86.50.nip.io/users/sign_in
```

Verify the host access path with:

```bash
GITLAB_DOMAIN="${GITLAB_DOMAIN:-192.168.86.50.nip.io}"
curl -I "https://gitlab.${GITLAB_DOMAIN}/users/sign_in"
```

## Use a LAN address

`192.168.86.50.nip.io` resolves to this GitLab host on the local network. For
other devices, assign the GitLab host a stable LAN address,
then create the ignored `.gitlab.env` file:

```bash
cp .gitlab.env.example .gitlab.env
```

Set the address consistently. For a host at `192.168.86.50`:

```bash
GITLAB_DOMAIN=192.168.86.50.nip.io
GITLAB_EXTERNAL_IP=192.168.86.50
GITLAB_SSH_HOST=gitlab.192.168.86.50.nip.io
```

Redeploy after changing it:

```bash
bash scripts/deploy_gitlab.sh
bash scripts/check_status.sh
```

The service is then available at
`https://gitlab.192.168.86.50.nip.io/`, with Git SSH on port `2222`. Reserve
the address outside the DHCP pool or create a DHCP reservation. If the host
uses a firewall, permit LAN TCP ports `80`, `443`, and `2222`.

## Trust the mkcert CA on LAN clients

Every client needs the GitLab host's mkcert root CA. Find it on the host:

```bash
mkcert -CAROOT
```

Copy only `rootCA.pem` to the client. Never copy `rootCA-key.pem`.

In Firefox, import `rootCA.pem` in **Settings → Privacy & Security →
Certificates → View Certificates → Authorities**, then select **Trust this CA
to identify websites**.

On Linux clients:

```bash
# Debian/Ubuntu
sudo install -m 0644 rootCA.pem /usr/local/share/ca-certificates/gitlab-mkcert.crt
sudo update-ca-certificates

# RHEL/AlmaLinux
sudo install -m 0644 rootCA.pem /etc/pki/ca-trust/source/anchors/gitlab-mkcert.crt
sudo update-ca-trust
```

From a different LAN computer, confirm forwarding and trust:

```bash
curl -Iv https://gitlab.192.168.86.50.nip.io/users/sign_in
```

An HTTP 200 response confirms the path. `unable to get local issuer
certificate` means the client has not trusted the mkcert CA.

## Regenerate the certificate

The helper writes its files under `.certs/` and includes the GitLab hostname,
the wildcard and base domain, `localhost`, and `127.0.0.1`. Regenerate whenever
the covered hostnames change:

```bash
FORCE_REGENERATE_CERT=true bash scripts/create_mkcert.sh
```

For a non-default domain or namespace, pass matching values to certificate
creation and deployment:

```bash
GITLAB_DOMAIN=gitlab.localtest.me NAMESPACE=my-gitlab bash scripts/create_mkcert.sh
GITLAB_DOMAIN=gitlab.localtest.me NAMESPACE=my-gitlab \
  GITLAB_DEPLOY_PROFILE=local-mkcert \
  bash scripts/deploy_gitlab.sh
```

## macOS note

Docker Desktop does not reliably publish container ports on a secondary LAN
address. A dedicated virtual IP needs a host-level forwarding solution and
persistent interface configuration. Test it from another LAN machine after
every change; `scripts/gitlab_vip_proxy_macos.sh` is obsolete and should not be
used.
