# Local HTTPS with mkcert

Use the default `local-mkcert` profile for a workstation or trusted LAN. It
does not require public DNS or port forwarding.

## Configure the address

The default is `192.168.86.50.nip.io`. To use another stable LAN address, copy
the example configuration:

```bash
cp .gitlab.env.example .gitlab.env
```

Set all three values to the same address:

```bash
GITLAB_DOMAIN=192.168.86.50.nip.io
GITLAB_EXTERNAL_IP=192.168.86.50
GITLAB_SSH_HOST=gitlab.192.168.86.50.nip.io
```

Reserve the address in DHCP and allow LAN TCP ports `80`, `443`, and `2222` in
the host firewall. Return to the shared [start command](README.md#quick-start).

## Trust the CA on other devices

Find the mkcert CA on the GitLab host:

```bash
mkcert -CAROOT
```

Copy only `rootCA.pem` to each client. Never copy `rootCA-key.pem`.

- Firefox: import `rootCA.pem` under **Privacy & Security → Certificates →
  Authorities** and trust it for websites.
- Debian/Ubuntu:
  `sudo install -m 0644 rootCA.pem /usr/local/share/ca-certificates/gitlab-mkcert.crt && sudo update-ca-certificates`
- RHEL/AlmaLinux:
  `sudo install -m 0644 rootCA.pem /etc/pki/ca-trust/source/anchors/gitlab-mkcert.crt && sudo update-ca-trust`

## Verify

```bash
GITLAB_DOMAIN="${GITLAB_DOMAIN:-192.168.86.50.nip.io}"
curl -I "https://gitlab.${GITLAB_DOMAIN}/users/sign_in"
```

A certificate issuer error means the client has not trusted the mkcert CA.

## Regenerate the certificate

Regenerate after changing the hostname:

```bash
FORCE_REGENERATE_CERT=true bash scripts/create_mkcert.sh
bash scripts/start_gitlab.sh
```

On macOS, Docker Desktop may not publish ports reliably on a secondary LAN
address. Test access from another LAN device after changing the address.
