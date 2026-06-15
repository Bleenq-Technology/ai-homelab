# Baserow

**Purpose:** No-code database / spreadsheet app.
**URL:** https://baserow.pdx.sanctioned.tech
**Auth:** local login (account created on first login)
**Image:** baserow/baserow:1.30.1
**Networks / data:** `proxy` + `data` networks; bind mount `./baserow/data` -> `/baserow/data`

## Setup as deployed
- `BASEROW_PUBLIC_URL=https://baserow.${DOMAIN}`. Serves on container port **80**; Traefik route `baserow.${DOMAIN}` (`websecure`, `secure-chain@file`).
- Backed by the unified Postgres: `DATABASE_HOST=postgres`, `DATABASE_PORT=5432`, `DATABASE_NAME=baserow`, `DATABASE_USER=baserow`, password `BASEROW_DB_PASSWORD` (DB/role provisioned by the Postgres init script).
- Uses Redis logical **DB 4**: `BASEROW_REDIS_URL=redis://:${REDIS_PASSWORD}@redis:6379/4` (also `REDIS_HOST=redis`, `REDIS_PORT=6379`, `REDIS_PASSWORD`).
- Django `SECRET_KEY` from `BASEROW_SECRET_KEY`.
- **First login:** open the URL and create the initial account/workspace (no SSO; native local auth).

## Fixes & gotchas
- None specific beyond pointing it at the shared Postgres (`baserow` DB) and Redis DB 4.

## Secrets
- `.env` keys: `BASEROW_DB_PASSWORD`, `REDIS_PASSWORD`, `BASEROW_SECRET_KEY`, `DOMAIN`, `TZ`.
- Real values live only in `/opt/homelab/.env` on jarvis (gitignored). Nothing sensitive is committed.
