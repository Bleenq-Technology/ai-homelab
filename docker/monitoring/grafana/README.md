# Grafana
**Purpose:** Dashboards and visualization for Prometheus metrics and Loki logs.
**URL:** https://grafana.pdx.sanctioned.tech
**Auth:** Native Keycloak OIDC (generic OAuth); local admin login kept as break-glass
**Image:** grafana/grafana:11.4.0
**Networks / data:** `proxy`, `monitoring`; named volume `grafana_data:/var/lib/grafana`, bind mounts `./grafana/provisioning` and `./grafana/grafana.ini` (read-only)

## Setup as deployed
- Auth is **native Keycloak OIDC** via Grafana's generic OAuth integration (Traefik uses `secure-chain@file`, not forward-auth — Grafana handles login itself):
  - `GF_AUTH_GENERIC_OAUTH_ENABLED=true`, name `Keycloak`, client ID `grafana`, scopes `openid email profile`.
  - Auth/token/userinfo URLs point at the Keycloak `homelab` realm (`https://keycloak.${DOMAIN}/realms/homelab/protocol/openid-connect/...`).
  - `GF_AUTH_GENERIC_OAUTH_USE_PKCE=true` (PKCE on), `LOGIN_ATTRIBUTE_PATH=preferred_username`, `ALLOW_SIGN_UP=true`.
  - `ROLE_ATTRIBUTE_PATH='Admin'` with `ROLE_ATTRIBUTE_STRICT=false` — every SSO user is mapped to **Admin for now**.
- Local admin login is kept as **break-glass**: `GF_SECURITY_ADMIN_USER` / `GF_SECURITY_ADMIN_PASSWORD`. `GF_USERS_ALLOW_SIGN_UP=false` disables non-OAuth self sign-up.
- `GF_SERVER_ROOT_URL=https://grafana.${DOMAIN}`; `TZ` set from env.
- Datasources and dashboards are auto-provisioned from `grafana/provisioning`. Exposed on container port 3000; routed at `grafana.${DOMAIN}` over `websecure` with TLS.

## Fixes & gotchas
- OIDC role mapping is intentionally coarse (`'Admin'` for all users) for the current single-admin phase; tighten via Keycloak realm roles / group claims later.
- Grafana terminates its own OIDC login, so it uses the `secure-chain@file` middleware rather than `secure-sso@file` forward-auth (which would double-auth).

## Secrets
- `GRAFANA_OIDC_CLIENT_SECRET` — Keycloak client secret for the `grafana` OAuth client.
- `GRAFANA_ADMIN_USER` / `GRAFANA_ADMIN_PASSWORD` — break-glass local admin.
- `DOMAIN`, `TZ` — non-secret config.
- Nothing sensitive is committed; real values live in `/opt/homelab/.env` (gitignored).
