# Infisical
**Purpose:** Secrets management — **the source of truth for all stack secrets.**
**URL:** https://infisical.pdx.sanctioned.tech
**Auth:** local login (account created on first visit)
**Image:** infisical/infisical:latest-postgres
**Networks / data:** `proxy` + `data` (external); no bind mount (state in Postgres/Redis)

## Setup as deployed
- Routed via Traefik: `Host(infisical.${DOMAIN})`, `websecure`, `tls=true`, `secure-chain@file`; service port `8080`.
- Postgres DB `infisical` via `DB_CONNECTION_URI` (`postgresql://infisical:${INFISICAL_DB_PASSWORD}@postgres:5432/infisical`).
- Redis DB 1 via `REDIS_URL` (`redis://:${REDIS_PASSWORD}@redis:6379/1`).
- `SITE_URL: https://infisical.${DOMAIN}`; `TZ` from `.env`.
- First login creates the initial admin account.

## Secrets source of truth (adopted)

All ~54 stack secrets live in the Infisical project **`homelab`**, environment **`prod`**.
At deploy time `/opt/homelab/.env` is **regenerated from Infisical** — it is a generated
artifact, never the source.

```bash
# on jarvis, in /opt/homelab
./pull-secrets.sh && docker compose -f compose.yml up -d
```

- [`pull-secrets.sh`](../../pull-secrets.sh) authenticates a **Machine Identity**
  (`jarvis-deploy`, Universal Auth) and runs `infisical export --format=dotenv > .env`.
- Machine-identity credentials live in `/opt/homelab/.infisical-auth` (chmod 600,
  gitignored): `INFISICAL_DOMAIN`, `INFISICAL_PROJECT_ID`, `INFISICAL_ENV`,
  `INFISICAL_CLIENT_ID`, `INFISICAL_CLIENT_SECRET`.
- Add/rotate a secret in the Infisical UI → re-run `pull-secrets.sh` → recreate the service.

### Bootstrap set (keep OUT of git AND Infisical — store in a password manager)

These can't come from Infisical because they're needed *before* Infisical (and its DB)
can serve secrets — this is the only out-of-band material:

| What | Why |
|------|-----|
| Machine-identity `CLIENT_ID` + `CLIENT_SECRET` | to authenticate `pull-secrets.sh` |
| `INFISICAL_ENCRYPTION_KEY` | **decrypts Infisical's stored secrets** — without it the data is unrecoverable |
| `INFISICAL_AUTH_SECRET`, `INFISICAL_DB_PASSWORD` | to start the Infisical service |
| `POSTGRES_SUPERUSER` / `POSTGRES_PASSWORD`, `REDIS_PASSWORD` | Infisical's DB + cache must be up first |
| EasyDNS `easydns_token` / `easydns_key` | already Docker secret files; also vault them |

Plus a regular **backup of the `infisical` Postgres database** (the encrypted secret store).
Backup + `INFISICAL_ENCRYPTION_KEY` together = restorable; either alone is useless.

### Rebuild from scratch

1. Provision host; install Docker + the Infisical CLI; clone repo to `/opt/homelab`.
2. Restore from the password manager: `/opt/homelab/.infisical-auth` and a minimal
   `.env` with just the **bootstrap set** above.
3. `docker network create proxy data ai monitoring`; restore `secrets/easydns_*`.
4. `docker compose up -d postgres redis infisical`, then restore the `infisical`
   Postgres DB from backup (so the project, secrets, and machine identity exist).
5. `./pull-secrets.sh` → full `.env` → `docker compose up -d` → full stack.

## Issues & Fixes
**Symptom:** none yet — Infisical adoption went cleanly (54/54 secrets imported, `infisical export` reproduced `.env` with zero value mismatches).
