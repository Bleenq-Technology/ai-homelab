# pgAdmin

**Purpose:** Web admin UI for the unified Postgres.
**URL:** https://pgadmin.pdx.sanctioned.tech
**Auth:** local login (`PGADMIN_DEFAULT_EMAIL` / `PGADMIN_DEFAULT_PASSWORD`)
**Image:** dpage/pgadmin4:8.14
**Networks / data:** `proxy` + `data` networks; bind mount `./pgadmin/data` -> `/var/lib/pgadmin`

## Setup as deployed
- Listens on container port **80**; Traefik route `pgadmin.${DOMAIN}` (`websecure`, `secure-chain@file`).
- `PGADMIN_LISTEN_PORT=80`, `PGADMIN_LISTEN_ADDRESS=0.0.0.0`.
- Log in with `PGADMIN_DEFAULT_EMAIL` / `PGADMIN_DEFAULT_PASSWORD`, then register a server pointing at host `postgres:5432` using the Postgres superuser (or a per-service role).

## Issues & Fixes

**Symptom:** The route returned `000` (connection timed out); inside the container pgAdmin listened only on `:::80` (IPv6) while Docker's network is IPv4.
**Fix:** Set `PGADMIN_LISTEN_ADDRESS=0.0.0.0`.

**Symptom:** The gunicorn worker exited with code 1 and the log said to "create a config_local.py file and override the SESSION_DB_PATH setting"; the route stayed `000`.
**Fix:** Chown the bind data directory to `5050:5050` (pgAdmin runs as uid 5050) so it can write its session database.

## Secrets
- `.env` keys: `PGADMIN_EMAIL`, `PGADMIN_PASSWORD`, `DOMAIN`, `TZ`.
- Real values live only in `/opt/homelab/.env` on jarvis (gitignored). Nothing sensitive is committed.
