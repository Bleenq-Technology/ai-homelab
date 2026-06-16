# QuestDB — time-series store for market / financial data

**Purpose:** Dedicated high-ingest time-series database for the trading project —
stock symbols, live feeds, historical bars/ticks. Deliberately **separate from
Prometheus/Loki** (those are infra observability with short retention); QuestDB is
the system-of-record for market data.
**URL (console):** https://questdb.pdx.sanctioned.tech
**Auth:** Keycloak forward-auth on the console (`secure-sso@file`); Postgres-wire is
password-auth; ILP ingest is open on the LAN (see *Security*).
**Image:** `questdb/questdb:9.4.3` (pinned). Runs as root; data root `/var/lib/questdb`.
**Networks:** `proxy`, `data`. **Data:** named volume `questdb_data:/var/lib/questdb`.

## Why QuestDB
Purpose-built for market data: designated timestamps, time-partitioned tables, and
**ASOF joins** (align trades↔quotes by nearest timestamp). Speaks the Postgres wire
protocol, so existing tooling (Grafana, pgAdmin, `psql`, any PG driver) just works.

## Interfaces / ports
| Port | Protocol | Exposure | Use |
|------|----------|----------|-----|
| **8812** | Postgres wire | host-published | SQL **queries** (password-auth) |
| **9009** | InfluxDB Line Protocol /TCP | host-published | high-throughput **ingest** |
| **9000** | HTTP — Web Console + REST + ILP/HTTP | **Traefik+SSO only** (not host-published) | console; REST `/exec` runs arbitrary SQL |
| **9003** | Prometheus metrics | internal | service health (Prom job `questdb`) |

> 9000 is intentionally **not** published to the host: its `/exec` REST endpoint
> executes arbitrary SQL with no auth, so it must stay behind Keycloak. Ingest goes
> through 9009 (or PG-wire INSERT); the console is reached at the URL above.

## Connect
**Query (Postgres wire)** — user `admin`, password = `QUESTDB_PG_PASSWORD`, db `qdb`:
```bash
psql "host=192.168.2.10 port=8812 user=admin password=<QUESTDB_PG_PASSWORD> dbname=qdb"
```
**Ingest (ILP/TCP, e.g. from the trading app)** — fire-and-forget lines to `:9009`:
```
trades,symbol=AAPL price=192.31,size=100 1718563200000000000
```
```python
# pip install questdb
from questdb.ingress import Sender, TimestampNanos
with Sender.from_conf("tcp::addr=192.168.2.10:9009;") as s:
    s.row("trades", symbols={"symbol": "AAPL"},
          columns={"price": 192.31, "size": 100}, at=TimestampNanos.now())
    s.flush()
```
A trading service running **as a container on the `data` network** can instead use
ILP-over-HTTP internally at `http://questdb:9000` (transactional, with error
feedback) without publishing any port.

## Grafana
Provisioned datasource **QuestDB** (type `postgres`, `questdb:8812`, db `qdb`),
reached over the shared `proxy` network. Credentials injected from
`QUESTDB_PG_USER` / `QUESTDB_PG_PASSWORD` (Infisical → `.env` → grafana env).

## Security
- **Console:** SSO-gated via Traefik. REST/console port 9000 not host-exposed.
- **Queries:** Postgres-wire requires the `QUESTDB_PG_PASSWORD`.
- **ILP ingest (9009):** unauthenticated, reachable on the LAN. Acceptable for a
  trusted home LAN; to lock down, enable ILP token auth or restrict the port to the
  trading host's IP. *Do not expose 9009/8812 to the internet.*

## Backup
Market data is **not** in the nightly `pg_dumpall` (that's the `postgres` service).
QuestDB data lives in the `questdb_data` volume — snapshot it, or use QuestDB
`CHECKPOINT`/`COPY` for consistent exports. Sizing can grow fast with tick data;
watch the `DiskSpaceLow` alert and partition/expire old data via `ALTER TABLE … DROP PARTITION`.

## DNS
Add an internal A record on the EdgeRouter: **`questdb.pdx.sanctioned.tech` → `192.168.2.10`**
(no `*.pdx` wildcard exists). The DB ports work by IP regardless.

## Secrets
- `QUESTDB_PG_PASSWORD` — Postgres-wire password (Infisical → `.env`).
- `QUESTDB_PG_USER` — defaults to `admin` (non-secret).
- `DOMAIN`, `TZ`. Nothing sensitive is committed.
