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

## `exampleapp` — the example-app DB (provisioned out-of-band)

The `example-app` product (sibling repo) gets a dedicated DB **`exampleapp`** with **two
least-privilege login roles**, provisioned by the idempotent
[`provision-exampleapp.sh`](provision-exampleapp.sh) — **not** the init script:

- **Why not `init/01-init-databases.sh`?** That only runs on a *first, empty* volume (ours is
  long populated), and the role passwords live in the **example-app Infisical project** (prod),
  not the homelab `.env` the init script sources. So `exampleapp` is provisioned separately;
  passwords are passed to the helper at run time and never baked into this repo (nothing for
  `docker/.env.example`).
- **The two roles** (deliberately bare — schema/grants/RLS are the example-app deploy's job via
  its `db.apply`/Alembic, **not** ours):
  - **`exampleapp_migrate`** — owns the DB, runs DDL/Alembic (the migration role). DDL-capable;
    not the role the running app connects as.
  - **`exampleapp_app`** — the runtime connect role. **NON-superuser AND NON-`BYPASSRLS`** so
    Row-Level Security actually binds it (the app sets `app.current_account_ids` per request).
    `db/apply.py` **refuses to deploy** if this role is `SUPERUSER`/`BYPASSRLS` — it would silently
    skip every `account_isolation` policy. The helper asserts `NOSUPERUSER NOBYPASSRLS` defensively.
- **Run:** `EXAMPLEAPP_MIGRATE_DB_PASSWORD=… EXAMPLEAPP_APP_DB_PASSWORD=… ./data/postgres/provision-exampleapp.sh`
- **Secrets home:** the **example-app** Infisical project (`prod`) — app role pw as
  `POSTGRES_PASSWORD`, migrate role pw as `MIGRATION_DB_PASSWORD` (+ `MIGRATION_DATABASE_URL`).
  The example-app deploy pulls them via its own `pull-secrets.sh`. (ai-homelab-infra todos #20.)
- The DB is picked up by the nightly `pg_dumpall` automatically.
