# QuestDB — time-series store for market / financial data

**Purpose:** Dedicated high-ingest time-series database for the trading project —
stock symbols, live feeds, historical bars/ticks. Deliberately **separate from
Prometheus/Loki** (those are infra observability with short retention); QuestDB is
the system-of-record for market data.
**URL (console):** https://questdb.pdx.sanctioned.tech
**Auth:** Keycloak SSO on the console (`secure-sso@file`); Postgres-wire is password-auth.
PG-wire (8812) and ILP (9009) are **internal-only** — not host-published (see *Security*).
**Image:** `questdb/questdb:9.4.3` (pinned). Runs as root; data root `/var/lib/questdb`.
**Networks:** `proxy`, `data`. **Data:** named volume `questdb_data:/var/lib/questdb`.

## Why QuestDB
Purpose-built for market data: designated timestamps, time-partitioned tables, and
**ASOF joins** (align trades↔quotes by nearest timestamp). Speaks the Postgres wire
protocol, so existing tooling (Grafana, pgAdmin, `psql`, any PG driver) just works.

## Interfaces / ports
| Port | Protocol | Exposure | Use |
|------|----------|----------|-----|
| **8812** | Postgres wire | internal only | SQL **queries** (password-auth) |
| **9009** | InfluxDB Line Protocol /TCP | internal only | high-throughput **ingest** |
| **9000** | HTTP — Web Console + REST + ILP/HTTP | **Traefik+SSO only** (not host-published) | console; REST `/exec` runs arbitrary SQL |
| **9003** | Prometheus metrics | internal | service health (Prom job `questdb`) |

> **No ports are host-published.** 8812/9009 are reachable only on the Docker `data`
> network (the on-jarvis trading engine connects via `questdb:8812` / `questdb:9009`);
> ILP has no auth in QuestDB OSS, so keeping it off the LAN is the security boundary.
> 9000's `/exec` REST endpoint executes arbitrary SQL with no auth, so it stays behind
> Keycloak via Traefik.

## Connect
Ports are internal-only, so connect from **inside the Docker `data` network** using the host
`questdb`. For an ad-hoc query from jarvis, run psql in a container, e.g.
`docker exec -it postgres psql "host=questdb port=8812 user=admin password=<…> dbname=qdb"`.

**Query (Postgres wire)** — host `questdb`, user `admin`, password = `QUESTDB_PG_PASSWORD`, db `qdb`:
```bash
psql "host=questdb port=8812 user=admin password=<QUESTDB_PG_PASSWORD> dbname=qdb"
```
**Ingest (ILP/TCP, e.g. from the trading app)** — fire-and-forget lines to `questdb:9009`:
```
trades,symbol=AAPL price=192.31,size=100 1718563200000000000
```
```python
# pip install questdb
from questdb.ingress import Sender, TimestampNanos
with Sender.from_conf("tcp::addr=questdb:9009;") as s:   # from a container on the `data` network
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

## Host tuning (mmap / file descriptors)
QuestDB is mmap- and file-descriptor-heavy and warns in its web console if limits are low:
- **`vm.max_map_count` ≥ 1048576** — set on the host (jarvis default 65530 is too low) via
  `/etc/sysctl.d/99-questdb.conf`:  `vm.max_map_count=1048576`, then `sudo sysctl --system`.
- **Per-container open files** — compose sets `ulimits.nofile` to `1048576` (the default cap
  of 524288 is below QuestDB's recommendation; the effective limit is
  `min(fs.file-max, nofile)`). `fs.file-max` is left at the kernel default (effectively
  unlimited) — do **not** lower it below a single process's nofile.

## Security
- **Console:** SSO-gated via Traefik. REST/console port 9000 not host-exposed.
- **Queries:** Postgres-wire requires the `QUESTDB_PG_PASSWORD`.
- **ILP ingest (9009) & PG-wire (8812):** **internal-only** — not host-published, reachable
  solely on the Docker `data` network (the on-jarvis trading engine uses `questdb:9009` /
  `questdb:8812`). ILP has no auth in QuestDB OSS, so keeping it off the LAN is the boundary.
  *Never host-publish or internet-expose these ports.*

## Backup
QuestDB **is** in the nightly `backup.sh`: it runs `CHECKPOINT CREATE`, tars the
`questdb_data` volume for a consistent snapshot, then `CHECKPOINT RELEASE` → local (rotated)
+ the MinIO `backups` bucket. Sizing can grow fast with tick data;
watch the `DiskSpaceLow` alert and partition/expire old data via `ALTER TABLE … DROP PARTITION`.

## DNS
Add an internal A record on the EdgeRouter: **`questdb.pdx.sanctioned.tech` → `192.168.2.10`**
(no `*.pdx` wildcard exists). The DB ports work by IP regardless.

## Secrets
- `QUESTDB_PG_PASSWORD` — Postgres-wire password (Infisical → `.env`).
- `QUESTDB_PG_USER` — defaults to `admin` (non-secret).
- `DOMAIN`, `TZ`. Nothing sensitive is committed.
