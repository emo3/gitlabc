# Public HTTPS with Let's Encrypt

Use this guide only when GitLab must be reachable from the public internet.
The `public-letsencrypt` profile uses cert-manager and Let's Encrypt HTTP-01
validation. For local-only development, use [README-mk.md](README-mk.md)
instead.

For shared setup, maintenance, backup and restore instructions, see
[README.md](README.md).

## Configure a public domain

Set the domain and ACME email in the ignored `.gitlab.env` file before
deploying:

```bash
GITLAB_DEPLOY_PROFILE=public-letsencrypt
GITLAB_PUBLIC_DOMAIN=your-public-domain.example
CERTMANAGER_EMAIL=admin@your-public-domain.example
```

`deploy_gitlab.sh` uses these values for the GitLab hostname, the ACME issuer,
and the URL it prints after deployment. Keep this profile setting in
`.gitlab.env` so subsequent deploys and starts use the public profile rather
than the default mkcert profile. Redeploy with this saved profile before
restoring data into a reset environment.

The domain's public DNS record must resolve to the host's current public IP.
If the address changes, use your DNS provider's dynamic-DNS mechanism to keep
the record current.

### Keep the Dynv6 address current with ddclient

For `edmo3.dynv6.net`, create an HTTP token for that zone in Dynv6, then install
`ddclient` on the GitLab host. Dynv6 exposes a DynDNS-compatible IPv4 update
endpoint, which `ddclient` can use with the zone token as its password. See the
[Dynv6 API documentation](https://dynv6.com/docs/apis) and
[ddclient configuration reference](https://ddclient.net/general.html) for
provider and package details.

On AlmaLinux/RHEL:

```bash
sudo dnf install -y ddclient
```

Configure the package's `ddclient.conf` (commonly `/etc/ddclient.conf`; check
the installed package if it uses another path):

```text
daemon=300
usev4=webv4, webv4=ipify-ipv4
protocol=dyndns2
server=dynv6.com
login=none
password=<DYNV6_ZONE_HTTP_TOKEN>
edmo3.dynv6.net
```

Replace the hostname with the value of `GITLAB_PUBLIC_DOMAIN` when using a
different Dynv6 zone. Keep the token out of this repository and restrict the
configuration file to root:

```bash
sudo chmod 600 /etc/ddclient.conf
sudo systemctl enable --now ddclient
sudo systemctl status ddclient
```

After the service starts, verify that public DNS returns the host's current WAN
IPv4 address before deploying GitLab. The Dynv6 DynDNS-compatible endpoint
updates IPv4; configure IPv6 separately if you publish an AAAA record.

## Satisfy HTTP-01 network requirements

Before deploying, all of these must be true:

- Public TCP ports 80 and 443 are forwarded by the router to the GitLab host.
- The host firewall permits inbound TCP 80 and 443.
- The k3d cluster exposes `80:80@loadbalancer` and `443:443@loadbalancer`.
  The provided Ansible playbook creates those mappings.
- The domain is reachable publicly; validation cannot be proven from the same
  LAN alone.

For an AlmaLinux/RHEL host using firewalld:

```bash
sudo firewall-cmd --permanent --add-port=80/tcp
sudo firewall-cmd --permanent --add-port=443/tcp
sudo firewall-cmd --reload
```

Configure equivalent router rules:

```text
External TCP 80  -> GitLab host TCP 80
External TCP 443 -> GitLab host TCP 443
```

## Deploy

Create or reconcile the k3d cluster, then deploy the public profile:

```bash
ansible-playbook -i localhost, --connection=local \
  ansible-install-k8s-tools-gitlab-deps.yml
bash scripts/deploy_gitlab.sh
bash scripts/check_status.sh
```

The deployment combines `.values/dev-external.values.yaml` with
`public-letsencrypt.values.yaml`, enables the bundled nginx ingress controller,
and asks cert-manager to obtain and renew the certificate.

## Validate certificate issuance and access

Inspect the ACME resources:

```bash
kubectl get issuer,certificate,challenge,order -n gitlab
kubectl get ingress -n gitlab
```

Then test from a network outside your LAN, such as a mobile connection:

```bash
curl -I https://gitlab.your-public-domain.example/users/sign_in
```

Use nginx ingress on host port 443 for browser access; do not use
`kubectl port-forward` or `:8080` as the public path.

If a Challenge remains pending, check public DNS, router forwarding, host
firewall rules, and whether the ISP blocks inbound TCP 80 or 443. A successful
certificate does not by itself prove that all external networks can reach the
service.

## Optional Web IDE extension host

The deploy helper keeps GitLab's upstream extension host,
`cdn.web-ide.gitlab-static.net`, by default. A custom extension host requires
working wildcard DNS and TLS first:

```bash
PUBLIC_WEB_IDE_EXTENSION_HOST_DOMAIN=webide.your-public-domain.example \
  bash scripts/deploy_gitlab.sh
```
