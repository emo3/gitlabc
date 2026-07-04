# TODO

## Public Web IDE hardening

Context: GitLab reports: "Web IDE single origin fallback is enabled."

Decision so far:
- Keep `local-mkcert` simple; do not harden Web IDE extension host for local-only dev.
- Apply the hardening only for `GITLAB_DEPLOY_PROFILE=public-letsencrypt`.

What to do next:
1. Identify the exact GitLab Rails setting/feature flag for disabling Web IDE single-origin fallback in GitLab v19.1.1.
2. Configure a dedicated public extension host domain, for example `webide.edmo3.dynv6.net` or `ide.edmo3.dynv6.net`.
3. Add that host to the public Let's Encrypt/DNS/ingress path.
4. Make `scripts/deploy_gitlab.sh` apply the setting only for `public-letsencrypt`.
5. Verify the Admin Area warning clears.

Discovery already done:
- `ApplicationSetting` columns matching Web IDE/static terms:
  - `editor_extensions`
  - `static_objects_external_storage_auth_token_encrypted`
  - `static_objects_external_storage_url`
  - `vscode_extension_marketplace`
  - `web_ide_oauth_application_id`
- The exact fallback setting name was not identified before pausing.
