# ClickHouse

**Purpose:** OLAP database. Two tenants: **Langfuse v3** analytics (`default` DB) and the
**`scanner`** ML research store (example-scanner).
**URL:** https://clickhouse.lab.example (HTTP interface, port 8123)
**Auth:** local login (`CLICKHOUSE_USER` / `CLICKHOUSE_PASSWORD`); read-only `scanner_ro` for Grafana.
**Image:** clickhouse/clickhouse-server:26.3.12.3
**Networks:** `proxy` + `data`. Grafana reaches it over the shared `proxy` network.

## Storage — it already lives on the SSD

The data dir is bind-mounted to **`/srv/ai-data/telemetry/clickhouse`** (owner `101:101`) — the
870 EVO 2 TB SATA SSD, moved off the nvme on 2026-06-28 for write-wear/thermal relief. See
[docs/storage-tiering-plan.md](../../../docs/storage-tiering-plan.md).

> **`telemetry/` vs `marketdata/` is a folder name, not a tier.** Both are directories on the
> *same ext4 filesystem on the same physical SSD* as QuestDB. Giving `scanner` a dedicated
> ClickHouse storage policy pointed at `marketdata/` would move bytes between folders on one
> disk — zero physical benefit. **Don't add a storage policy.** `scanner` stays on the `default`
> disk; capacity is governed by the alerts + retention below. (Answered for todos.md #25.)

## Tenancy

| DB | Owner | Notes |
|---|---|---|
| `default` | Langfuse v3 | `traces`, `observations`, `scores` (+ views). **Don't hand-edit** — Langfuse owns the migrations. |
| `scanner` | example-scanner | `bars_1m`, `trades`. Its jobs own the schema (`backtest/bar_store.py ensure_schema`). |
| `system` | ClickHouse | Internal log tables — see TTLs below. |

## Retention (all of it is disposable)

Nothing in ClickHouse is irreplaceable: Langfuse traces are observability, `scanner` reloads
idempotently (ReplacingMergeTree) from the market-data source, and `system` is self-telemetry.
Retention is set accordingly.

- **`config/logs-ttl.xml`** bounds the `system.*_log` tables (7 d for the sampling firehoses,
  14 d for metrics/query/part, 90 d error, 365 d backup). Before this, they had **no TTL at all**
  and had grown to **5.65 GiB — 97% of ClickHouse's entire footprint** (trace_log alone: 136 M
  rows). Two gotchas are documented in that file; read them before editing it.
- **Langfuse traces: 14-day TTL** on `traces` / `observations` / `scores` (applied by `ALTER`,
  2026-07-09). Paul's call: traces are "only marginally interesting for about a week".
  A future Langfuse migration could reset these — re-check after a Langfuse upgrade.
- **`scanner`: no TTL.** `/srv/ai-data` has ~1.7 T free and the trades tape backfill is only
  tens of GB, so a hard TTL would be premature and lossy for research. Instead:
  `ClickHouseUserDataLarge` fires at **300 GB** of user data (see
  `monitoring/prometheus/alert_rules.yml`) — that's the agreed point to revisit. `bars_1m` is
  `PARTITION BY toYYYYMM(ts)`, so retention is a cheap partition drop when it's wanted:
  ```sql
  -- drop a month once it's past the research window
  ALTER TABLE scanner.trades DROP PARTITION '202401';
  ```

## Backups — ClickHouse is excluded on purpose (mostly)

`backup.sh` runs `BACKUP ALL EXCEPT DATABASES system, information_schema, scanner`.

- **`system` excluded** — it was 97% of the dump. The nightly zip went **3.3 G → 45 M**, and that
  noise had also been copied into MinIO and shipped off-host to the NAS every night.
- **`scanner` excluded** — large and reproducible. Back it up on demand if a backfill was
  expensive enough to be worth keeping:
  ```bash
  docker exec clickhouse clickhouse-client -q "BACKUP DATABASE scanner TO File('scanner-$(date +%F).zip')"
  docker cp clickhouse:/var/lib/clickhouse/backups/scanner-$(date +%F).zip /srv/ai-data/backups/
  ```
  (The NAS has plenty of room if we ever want this on a schedule.)
- What *is* backed up: Langfuse's `default` DB — cheap, and its schema/migration state is
  annoying to rebuild.

## The `scanner_ro` user (Grafana)

Created in ClickHouse's **SQL access store** (persists in `/var/lib/clickhouse/access`; enabled by
`CLICKHOUSE_DEFAULT_ACCESS_MANAGEMENT=1`), *not* from `.env` — only its password is carried in
`.env`/Infisical as `CLICKHOUSE_SCANNER_RO_PASSWORD` for Grafana to consume.

It can `SELECT` `scanner.*` and a few `system` schema tables, nothing else: `readonly=2`, a
60 s `max_execution_time`, 4 GB memory cap and an hourly query quota, so a runaway dashboard
can't OOM the box that also serves Langfuse. Verified: `INSERT`/`CREATE`/`DROP`, `default.traces`
and `system.query_log` all return **Code 497 ACCESS_DENIED**; `SHOW DATABASES` shows only `scanner`.

To rotate:
```bash
cd /opt/homelab
PW=$(openssl rand -hex 24)
./push-secret.sh CLICKHOUSE_SCANNER_RO_PASSWORD "$PW"
docker exec -i clickhouse clickhouse-client -q "ALTER USER scanner_ro IDENTIFIED WITH sha256_password BY '$PW'"
./pull-secrets.sh && docker compose -f compose.yml up -d grafana
```

## The `ai_audit_writer` user (AI audit record)

Append-only writer for `ai_governance.gateway_calls` — the long-lived AI audit record (todos.md #40).
`export-audit.sh` connects as this user, not admin, so a compromised export path cannot erase the
record. Can `CREATE`/`INSERT`/`SELECT`/`OPTIMIZE` on `ai_governance`; **denied** `DELETE`/`TRUNCATE`/
`ALTER`/`DROP` (verified: Code 497). Defined in `docker/ai/audit/writer-role.sql`; password in Infisical
as `CLICKHOUSE_AI_AUDIT_WRITER_PASSWORD`. Rotate the same way as `scanner_ro`
(`ALTER USER ai_audit_writer IDENTIFIED WITH sha256_password BY '<new>'`). See
[`docker/ai/audit/README.md`](../../ai/audit/README.md).

## Setup as deployed
- `CLICKHOUSE_DB=default`, `CLICKHOUSE_DEFAULT_ACCESS_MANAGEMENT=1`; user/password from
  `CLICKHOUSE_USER` / `CLICKHOUSE_PASSWORD`.
- `ulimits.nofile` raised to 262144 (soft/hard) as ClickHouse requires.
- Traefik route `clickhouse.${DOMAIN}` -> port **8123** (`websecure`, `secure-chain@file`).
  Healthcheck hits `http://localhost:8123/ping`.
- `config/keeper.xml` enables embedded **ClickHouse Keeper** plus the required `macros`.
- `config/prometheus.xml` exposes native metrics on `:9363` (scraped as job `clickhouse`).
- `config/logs-ttl.xml` bounds the system log tables.

## Issues & Fixes

**Symptom:** Langfuse failed at startup with `Applying clickhouse migrations failed` (it creates
ReplicatedMergeTree tables); and after Keeper was added on top of the existing data, ClickHouse
exited with code 127.
**Fix:** Mount `config/keeper.xml` to enable embedded ClickHouse Keeper + macros, AND wipe the
pre-existing (non-Keeper) data directory so it starts clean.

**Symptom (2026-07-09): ClickHouse crash-loops after adding system-log TTLs**, with
`Code: 36 ... If 'engine' is specified for system table, TTL parameters should be specified
directly inside 'engine' and 'ttl' setting doesn't make sense (BAD_ARGUMENTS)`.
**Cause:** `opentelemetry_span_log` is the one log whose stock `config.xml` section declares an
explicit `<engine>`; a sibling `<ttl>` is rejected. **Fix:** put its retention *inside* a replaced
`<engine>` (and use `finish_date` — it has no `event_date`). See the comments in `logs-ttl.xml`.

**Note — changing a system log's definition renames the old table.** ClickHouse renames
`system.trace_log` → `system.trace_log_1` and creates a fresh one. That's where the old `_0`
tables came from. After a TTL change, drop the leftovers to reclaim the space:
```sql
SELECT name FROM system.tables WHERE database='system' AND match(name,'_log_[0-9]+$');
```

## Secrets
- `.env` keys: `CLICKHOUSE_USER`, `CLICKHOUSE_PASSWORD`, `CLICKHOUSE_SCANNER_RO_USER`,
  `CLICKHOUSE_SCANNER_RO_PASSWORD`, `DOMAIN`, `TZ`.
- Real values live only in Infisical → `/opt/homelab/.env` (gitignored). Nothing sensitive is committed.
