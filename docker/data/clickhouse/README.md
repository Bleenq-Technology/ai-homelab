# ClickHouse

**Purpose:** OLAP database; analytics backend for Langfuse v3.
**URL:** https://clickhouse.pdx.sanctioned.tech (HTTP interface, port 8123)
**Auth:** local login (`CLICKHOUSE_USER` / `CLICKHOUSE_PASSWORD`)
**Image:** clickhouse/clickhouse-server:24.12
**Networks / data:** `proxy` + `data` networks; bind mount `./clickhouse/data` -> `/var/lib/clickhouse`, plus `./clickhouse/config/keeper.xml` -> `/etc/clickhouse-server/config.d/keeper.xml` (read-only)

## Setup as deployed
- `CLICKHOUSE_DB=default`, `CLICKHOUSE_DEFAULT_ACCESS_MANAGEMENT=1`; user/password from `CLICKHOUSE_USER` / `CLICKHOUSE_PASSWORD`.
- `ulimits.nofile` raised to 262144 (soft/hard) as ClickHouse requires.
- Traefik route `clickhouse.${DOMAIN}` -> port **8123** (`websecure`, `secure-chain@file`). Healthcheck hits `http://localhost:8123/ping`.
- `config/keeper.xml` enables embedded **ClickHouse Keeper** plus the required `macros`.

## Issues & Fixes

**Symptom:** Langfuse failed at startup with `Applying clickhouse migrations failed` (it creates ReplicatedMergeTree tables); and after Keeper was added on top of the existing data, ClickHouse exited with code 127.
**Fix:** Mount `config/keeper.xml` to enable embedded ClickHouse Keeper + macros, AND wipe the pre-existing (non-Keeper) data directory so it starts clean.

## Secrets
- `.env` keys: `CLICKHOUSE_USER`, `CLICKHOUSE_PASSWORD`, `DOMAIN`, `TZ`.
- Real values live only in `/opt/homelab/.env` on jarvis (gitignored). Nothing sensitive is committed.
