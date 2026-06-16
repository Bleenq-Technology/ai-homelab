# Keycloak SSO

Keycloak is the homelab identity provider. Realm **`homelab`** holds the users and
the OIDC clients; `master` is kept for Keycloak admin only.

## How services authenticate

- **Native OIDC** (the app talks to Keycloak directly): Grafana, Open WebUI,
  Portainer, Langfuse. Each has its own confidential client + redirect URI.
- **Forward-auth** (for apps with no/weak SSO): `traefik-forward-auth` is a Keycloak
  client (`oauth2-proxy`) that Traefik calls via the `sso@file` / `secure-sso@file`
  middleware. On no session it 307-redirects to Keycloak; one shared cookie on
  `.${DOMAIN}` gives SSO across all gated apps. Currently gates Prometheus,
  Alertmanager, SearXNG, ComfyUI. Add more by setting their router middleware to
  `secure-sso@file` **and** adding `https://<host>.<domain>/_oauth` to the
  `oauth2-proxy` client's redirect URIs.
- The **Traefik dashboard** stays on basic-auth as a deliberate break-glass.
- **n8n / Flowise** gate OIDC behind paid tiers; **NetBox** needs a remote-auth
  plugin — these keep local logins (or can be forward-auth gated later).

Client secrets live in `/opt/homelab/.env` on the host (`*_OIDC_CLIENT_SECRET`,
`OAUTH2_PROXY_CLIENT_SECRET`), never in git.

## Reproducing the realm

[`realm-homelab.json`](realm-homelab.json) is a sanitized export (client secrets
replaced with `REPLACE_AFTER_IMPORT`). To recreate the realm on a fresh Keycloak:

```bash
# import the realm
docker exec keycloak /opt/keycloak/bin/kcadm.sh config credentials \
  --server http://localhost:8080 --realm master --user admin --password "$KEYCLOAK_ADMIN_PASSWORD"
docker cp docker/core/keycloak/realm-homelab.json keycloak:/tmp/realm.json
docker exec keycloak /opt/keycloak/bin/kcadm.sh create realms -f /tmp/realm.json

# then regenerate each client secret and write it back into .env, e.g.:
docker exec keycloak /opt/keycloak/bin/kcadm.sh get clients -r homelab -q clientId=grafana --fields id
docker exec keycloak /opt/keycloak/bin/kcadm.sh create clients/<id>/client-secret -r homelab
```

Recreate the user (`paul`) and set a password with `create users` / `set-password`.

## Email / SMTP (password reset, verification)

The realm sends mail via **Mailjet** using the shared `SMTP_*` creds (Infisical →
`.env`), with **password reset** and **email verification** enabled. Apply (or
re-apply after a realm rebuild) with the idempotent helper:

```bash
./core/keycloak/configure-smtp.sh      # run from /opt/homelab
```

It reads `SMTP_*` + the admin creds from `.env` and sets `realms/homelab`
`smtpServer` + `resetPasswordAllowed` + `verifyEmail` via `kcadm`.

**Notes & gotchas:**
- kcadm can't set the `smtpServer` map with `-s key.subkey=...` and `--fields
  smtpServer` won't echo a nested map back — the script applies a JSON file with
  `-f` (read the *full* realm to verify, not `--fields`).
- The `SMTP_FROM` address must be a **Mailjet-verified sender** or mail is rejected.
- Mailjet SMTP: port **587**, **StartTLS** (`ssl=false`, `starttls=true`),
  `user` = API key, `password` = secret key.
- The same `SMTP_*` creds are reused by Grafana, NetBox, and Baserow.
