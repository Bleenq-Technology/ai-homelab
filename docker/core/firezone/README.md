# Firezone — DEFERRED (not running)
**Purpose:** WireGuard VPN with Keycloak SSO. **Currently deferred / stopped.**
**URL:** (intended) https://vpn.pdx.sanctioned.tech — not serving
**Auth:** (intended) Keycloak OIDC, client `firezone`
**Image:** firezone/firezone:0.7.36 (EOL)
**Networks / data:** `proxy` + `data` (external); binds `./firezone/data` and `/lib/modules` (ro); UDP `51820` published

## Status
This service is **deferred and intentionally not running.**
- Image `firezone/firezone:0.7.36` is end-of-life.
- On start it crash-looped, demanding `DATABASE_ENCRYPTION_KEY` plus a long list of additional required env vars, so we stopped it.
- **Recommendation:** replace with **NetBird** (WireGuard + Keycloak SSO) rather than reviving this image.

## Intended config (for reference, if revived)
- `EXTERNAL_URL: https://vpn.${DOMAIN}`, WireGuard IPv4 `10.44.0.0/24` / IPv6 `fd00:44::/64`, port `51820/udp`.
- Postgres DB `firezone`; OIDC against `https://keycloak.${DOMAIN}/realms/master`, client `firezone`, redirect `/auth/oidc/callback`.
- Traefik route would target service port `13000`.

## Secrets (would be needed)
- `.env` keys referenced: `FIREZONE_ADMIN_EMAIL`, `FIREZONE_ADMIN_PASSWORD`, `FIREZONE_SECRET_KEY_BASE`, `FIREZONE_LIVE_VIEW_SIGNING_SALT`, `FIREZONE_COOKIE_SIGNING_SALT`, `FIREZONE_COOKIE_ENCRYPTION_SALT`, `FIREZONE_DB_PASSWORD`, `FIREZONE_OIDC_CLIENT_SECRET`, `DOMAIN`, `TZ`.
- Nothing sensitive is committed to git.
