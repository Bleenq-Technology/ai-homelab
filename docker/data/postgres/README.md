# Postgres

**Purpose:** Single unified PostgreSQL host for the whole lab; one DB + role per dependent service.
**URL:** internal / no UI (admin via pgAdmin)
**Auth:** local login (superuser + per-service roles)
**Image:** postgres:16
**Networks / data:** `data` network; named volume `postgres_data` mounted at `/var/lib/postgresql/data` (Docker-managed ownership)

## Setup as deployed
- Container/host name `postgres`; reachable by other stacks at `postgres:5432` on the `data` network.
- Superuser from `POSTGRES_SUPERUSER` / `POSTGRES_PASSWORD`; default DB `postgres`. `PGDATA=/var/lib/postgresql/data/pgdata`.
- `./postgres/init` is mounted read-only at `/docker-entrypoint-initdb.d`. On first boot of an empty data dir, `init/01-init-databases.sh` creates one database plus a least-privilege LOGIN role for each dependent service: **keycloak, netbox, infisical, baserow, langfuse, firezone**. Each role's password comes from its `*_DB_PASSWORD` env key.
- The init script is idempotent (checks `pg_roles` / `pg_database` before creating) but only runs automatically on an empty volume — re-running against a populated volume requires manual invocation.

## Issues & Fixes

**Symptom:** The container crash-looped (status `Restarting`); logs showed `FATAL: data directory "/var/lib/postgresql/data" has wrong ownership` and `PostgreSQL Database directory appears to contain a database; Skipping initialization`.
**Fix:** Use the standard `postgres:16` image (not `supabase/postgres`) with a NAMED volume — the supabase image ships a pre-baked data directory that Docker copied into the volume with mismatched ownership.

## Secrets
- `.env` keys: `POSTGRES_SUPERUSER`, `POSTGRES_PASSWORD`, and the per-service role passwords `KEYCLOAK_DB_PASSWORD`, `NETBOX_DB_PASSWORD`, `INFISICAL_DB_PASSWORD`, `BASEROW_DB_PASSWORD`, `LANGFUSE_DB_PASSWORD`, `FIREZONE_DB_PASSWORD`. Also `TZ`.
- Real values live only in `/opt/homelab/.env` on jarvis (gitignored). Nothing sensitive is committed; `docker/.env.example` holds placeholders.
