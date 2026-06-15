# Uptime Kuma
**Purpose:** Self-hosted uptime / status monitoring with its own probes and status pages.
**URL:** https://uptime.pdx.sanctioned.tech
**Auth:** local login (Uptime Kuma's own account; Traefik uses `secure-chain@file`, no forward-auth)
**Image:** louislam/uptime-kuma:1.23.16
**Networks / data:** `proxy`, `monitoring`; named volume `uptime_kuma_data:/app/data`

## Setup as deployed
- Exposed on container port 3001; Traefik routes `uptime.${DOMAIN}` over `websecure` with TLS via the `secure-chain@file` middleware.
- Not behind Keycloak forward-auth — Uptime Kuma manages its own authentication.
- All state (monitors, settings, the admin account) persists to the `uptime_kuma_data` volume.

## Fixes & gotchas
- The **admin account is created on first login** (initial setup screen) — it is not provisioned via env or compose.

## Secrets
- None in compose. The admin credentials are set interactively at first login and stored in the `uptime_kuma_data` volume.
- Nothing sensitive is committed; real values live in `/opt/homelab/.env` (gitignored).
