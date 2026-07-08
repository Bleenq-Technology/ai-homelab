# Infisical
**Purpose:** Secrets management — **the source of truth for all stack secrets.**
**URL:** https://infisical.lab.example
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
- **Or from the CLI** with [`push-secret.sh`](../../push-secret.sh) — the write counterpart to
  `pull-secrets.sh`, using the same `jarvis-deploy` machine identity (which has write access):
  ```bash
  ./push-secret.sh KEY VALUE     # set/rotate KEY to VALUE in homelab/prod
  ./push-secret.sh KEY           # set KEY from its current ./.env value
  ```
  The value is never printed (only its length). Use this so any var added to `.env` also lands in
  Infisical — otherwise the next `pull-secrets.sh` regen drops it (exactly how
  `CONTENT_CURATOR_DB_PASSWORD` got emptied before it was pushed).

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
**Symptom (2026-07-08): phantom "credential drift" — `.env` values fail auth (401) while the
same keys work inside containers.** Root cause: Infisical CLI ≥ 0.38 changed `infisical export
--format=dotenv` to wrap every value in **single quotes** (`KEY='value'`). Docker compose strips
quotes at interpolation, so services kept working — but every *raw* reader broke silently:
`grep|cut` scripts, `docker run --env-file`, and curl tests all treated the quotes as part of the
value. This manufactured the TODO #24 "three clocks drift" (all keys were in fact in sync and
alive). **Fix:** `pull-secrets.sh` now strips the wrapping quotes so `.env` stays raw values.
Two related CLI gotchas found the same day: `secrets delete` under a **machine-identity** token
defaults to `--type=personal` and 400s ("Must be user to delete personal secret") — pass
**`--type=shared`** (or use the raw API `DELETE /api/v3/secrets/raw/<KEY>`); and don't trust
`secrets get` read-backs alone to conclude export state — compare against `infisical export`.

**CLI install (2026-07-08):** upgraded 0.38.0 → **0.43.101** from Infisical's own apt repo
(`https://artifacts-cli.infisical.com` via their `setup.deb.sh`); the old Cloudsmith source is
frozen at 0.38 (left disabled at `sources.list.d/infisical-infisical-cli.list.disabled`).
0.43.101 **still single-quotes export values**, so the `pull-secrets.sh` strip stays. Verified
post-upgrade: `pull-secrets.sh` reproduced a byte-identical `.env` (103 secrets) and the master
key tested 200 through the gateway.

Earlier: adoption itself went cleanly (54/54 secrets imported, `infisical export` reproduced
`.env` with zero value mismatches — on the pre-0.38, unquoted CLI).
