# Public HTTPS with Let's Encrypt

Use `public-letsencrypt` only when GitLab must be reachable from the public
internet. Local deployments should use [mkcert](README-mk.md).

## Configure the domain

Copy the local template, then add the public profile settings to the ignored
`.gitlab.env` file:

```bash
cp .gitlab.env.example .gitlab.env
```

```dotenv
GITLAB_DEPLOY_PROFILE=public-letsencrypt
GITLAB_PUBLIC_DOMAIN=your-public-domain.example
CERTMANAGER_EMAIL=admin@your-public-domain.example
```

The domain's public DNS record must point to the host's current public IP. Keep
the profile in `.gitlab.env` so future starts and restores use it.

### Dynamic DNS (optional)

If the public IP changes, use the DNS provider's update client. For Dynv6,
install `ddclient`, create a zone HTTP token, and configure:

```text
daemon=300
usev4=webv4, webv4=ipify-ipv4
protocol=dyndns2
server=dynv6.com
login=none
password=<DYNV6_ZONE_HTTP_TOKEN>
your-public-domain.example
```

Store the configuration as root-only and enable `ddclient`. See the
[Dynv6 API](https://dynv6.com/docs/apis) and
[ddclient documentation](https://ddclient.net/general.html) for installation
details.

## Open the public ports

Forward router TCP ports `80` and `443` to the GitLab host and permit them in
the host firewall. For firewalld:

```bash
sudo firewall-cmd --permanent --add-port=80/tcp
sudo firewall-cmd --permanent --add-port=443/tcp
sudo firewall-cmd --reload
```

Public DNS and port 80 must work from outside the LAN for Let's Encrypt HTTP-01
validation. Return to the shared [start command](README.md#quick-start).

## Verify

```bash
kubectl get issuer,certificate,challenge,order -n gitlab
curl -I https://gitlab.your-public-domain.example/users/sign_in
```

Run the `curl` test from outside the LAN. If a challenge remains pending, check
public DNS, router forwarding, the host firewall, and whether the ISP blocks
inbound ports `80` or `443`.
