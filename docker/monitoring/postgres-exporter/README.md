# Postgres Exporter
**Purpose:** Exposes PostgreSQL server and database metrics for Prometheus.
**URL:** internal / no UI
**Auth:** none (internal-only, not exposed via Traefik)
**Image:** prometheuscommunity/postgres-exporter:v0.16.0
**Networks / data:** `data`, `monitoring`; no volumes

## Setup as deployed
- Connects via `DATA_SOURCE_NAME` built from env:
  `postgresql://${POSTGRES_SUPERUSER}:${POSTGRES_PASSWORD}@postgres:5432/postgres?sslmode=disable`.
- Attaches to both `data` (to reach the `postgres` service) and `monitoring` (so Prometheus can scrape it as the `postgres-exporter` target). No Traefik route.

## Fixes & gotchas
- `sslmode=disable` is used because `postgres` is reached over the internal `data` network.

## Secrets
- `POSTGRES_SUPERUSER` and `POSTGRES_PASSWORD` — superuser credentials embedded in the DSN.
- Nothing sensitive is committed; real values live in `/opt/homelab/.env` (gitignored). `docker/.env.example` ships placeholders only.
