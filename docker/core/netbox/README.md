# NetBox
**Purpose:** IPAM / DCIM — source of truth for IP space and infrastructure inventory.
**URL:** https://netbox.pdx.sanctioned.tech
**Auth:** local login (superuser created on first boot)
**Image:** lscr.io/linuxserver/netbox:latest
**Networks / data:** `proxy` + `data` (external); binds `./netbox/config` -> `/config`

## Setup as deployed
- Routed via Traefik: `Host(netbox.${DOMAIN})`, `websecure`, `tls=true`, `secure-chain@file`; service port **8000** (see gotcha).
- `ALLOWED_HOST: netbox.${DOMAIN}`.
- Postgres DB `netbox` (`DB_HOST=postgres`, `DB_USER=netbox`, `DB_PASSWORD=${NETBOX_DB_PASSWORD}`).
- Redis on `redis:6379` with `REDIS_PASSWORD`; DB **2** for tasks (`REDIS_DB_TASK`) and DB **3** for cache (`REDIS_DB_CACHE`).
- Superuser auto-created from `SUPERUSER_EMAIL` / `SUPERUSER_PASSWORD`.

## Issues & Fixes

**Symptom:** https://netbox.pdx.sanctioned.tech returned 502 even with the container running.
**Fix:** Set the Traefik loadbalancer server port to 8000 — the lscr.io/linuxserver/netbox image serves HTTP on 8000, not 8080. (Note: NetBox's first boot is slow due to DB migrations, so a 502 during initial startup is expected.)

## Secrets
- `.env` keys: `NETBOX_ADMIN_EMAIL` (defaults to `admin@pdx.sanctioned.tech`), `NETBOX_ADMIN_PASSWORD` (placeholder default — override), `NETBOX_DB_PASSWORD`, `REDIS_PASSWORD`, `DOMAIN`, `TZ`.
- Nothing sensitive is committed to git.
