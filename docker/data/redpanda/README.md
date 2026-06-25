# Redpanda — Kafka-API event / streaming spine

**Purpose:** Shared, durable **event/streaming backbone** for the lab — collectors publish
facts to per-domain topics; independent sinks consume them (durable buffering, **replay**,
multi-consumer fan-out, backpressure). Filed by `example-app` (TODO #17) whose data
architecture is built around it (Alpaca market-data → topic → QuestDB sink + scanner +
enrichers), and reusable by any data-heavy project.
**Endpoint:** `redpanda:9092` (Kafka API) — **internal `data` network only, not host-published.**
**Console URL:** https://redpanda.lab.example (Keycloak SSO via oauth2-proxy).
**Image:** `redpandadata/redpanda:v26.1.10` · Console `redpandadata/console:v3.7.4` (pinned).
**Runs as:** uid/gid **`101:101`** (the image's `redpanda` user) — the data dir must be owned by it.
**Networks:** broker `data`; Console `proxy`+`data`.
**Data:** named volume `redpanda_data` → **bind-backed on the SSD** at
`/srv/ai-data/streaming/redpanda` (see *Storage* below).

## Why Redpanda
Kafka-API compatible, **single binary, no ZooKeeper/JVM** — far lighter to operate than Kafka
and fine on jarvis (amd64). One broker gives us the spine; we run it capped so it co-exists with
the rest of the modest host.

## Not a system-of-record
Single broker, **replication factor 1** → the log is a **durable buffer + replay history**, not
the SoR. The systems of record are the sinks (**QuestDB**, **Postgres**), which *are* in
`backup.sh`. Redpanda's volume is therefore **deliberately excluded from restic backups** (same
stance as Prometheus/Loki) — on total loss, producers re-emit and sinks already hold the
durable copy.

## Interfaces / ports (all internal to the `data` network)
| Port | API | Use |
|------|-----|-----|
| **9092** | Kafka | produce / consume (clients connect as `redpanda:9092`) |
| **8081** | Schema Registry | Avro/Protobuf/JSON schemas (built-in; for the "schema registry" need) |
| **9644** | Admin + **metrics** | `GET /public_metrics` (Prometheus) + cluster admin (used by Console) |
| **33145** | RPC (internal) | intra-cluster RPC (single node, but must bind) |

> **No ports are host-published.** Like QuestDB ILP, the security boundary is "off the LAN":
> the Kafka API has **no auth** (internal-network trust) so it must never be host-exposed. Only
> the **Console** is reachable from the LAN, and only **behind Keycloak SSO** via Traefik.

## Resource caps (modest shared host)
The broker is started with `--smp 1 --memory 1G --reserve-memory 0M --overprovisioned`:
- `--smp 1` — one CPU core.
- `--memory 1G` — hard cap on Redpanda's allocation (bump if buffering grows).
- `--overprovisioned` — **critical on a shared box**: disables thread-affinity/busy-polling so
  Redpanda doesn't peg a core when idle.
We do **not** use `--mode dev-container` — it bundles `--unsafe-bypass-fsync` (data-loss risk on
power cut) and `auto_create_topics_enabled=true`. We keep **fsync on** and topics **governed**.

## Topic conventions
Auto-create is **off** (`redpanda.auto_create_topics_enabled=false`) so the spine stays governed —
each producing app creates its own topics deliberately, with the right retention/partitioning.

- **Name:** `domain.entity`, lower-case, dot-namespaced per data domain —
  `market.bars`, `market.quotes`, `news.articles`, `filings.raw`, …
- **Partitions:** start small (1–3); pick by consumer parallelism, not optimism (single broker).
- **Replication:** **1** (single broker; RF>1 needs more brokers).
- **Retention / cleanup** — match the data's value:
  - high-rate streams short, e.g. `market.quotes` `retention.ms≈86400000` (24 h);
  - facts longer, e.g. `news.articles` ~30 d;
  - keyed latest-value topics → `cleanup.policy=compact`.

Create a topic (from any container on the `data` network, or `docker exec redpanda …`):
```bash
rpk topic create market.bars -p 3 -r 1 \
  -c retention.ms=604800000 -c cleanup.policy=delete
rpk topic list
```

## Produce / consume
From a container on the `data` network (clients bootstrap to `redpanda:9092`):
```bash
# quick round-trip with rpk
rpk -X brokers=redpanda:9092 topic produce market.bars     # type lines, Ctrl-D
rpk -X brokers=redpanda:9092 topic consume market.bars -n 1
```
```python
# kafka-python / confluent-kafka / aiokafka — all speak the Kafka API
from confluent_kafka import Producer
p = Producer({"bootstrap.servers": "redpanda:9092"})
p.produce("market.bars", key="AAPL", value='{"o":192.3,"c":192.5}')
p.flush()
```

## Console
`redpanda-console` (web UI) is on `proxy`+`data`, gated by **`secure-sso@file`** (oauth2-proxy
forward-auth — **no per-app Keycloak client**, it shares the one oauth2-proxy client). It wires to
the broker, Schema Registry, and Admin API over internal URLs (see compose env). Use it for live
topic browsing, per-partition offsets, **consumer-group lag**, and message inspection.

## Monitoring
- **Prometheus** scrapes `redpanda:9644/public_metrics` as job **`redpanda`**.
- **Grafana** dashboard **"Redpanda"** (provisioned): throughput, partition health, disk, and
  **consumer-group lag** (the "are the sinks keeping up?" signal — only populates once a consumer
  with committed offsets is attached).
- **Alerts** (`prometheus/alert_rules.yml`): unavailable partitions, disk low, high consumer lag →
  the existing Discord channel.

## Storage
Backed by the **870 EVO SSD** at `/srv/ai-data/streaming/redpanda` (the heavy-write tier per
[`docs/storage-tiering-plan.md`](../../../docs/storage-tiering-plan.md)) — a continuous append
log belongs off the nvme for write-wear/thermal relief, and being greenfield it was placed there
from day one (no migration). The compose `redpanda_data` volume is **bind-backed** to that path:
```yaml
redpanda_data:
  driver: local
  driver_opts: { type: none, o: bind, device: /srv/ai-data/streaming/redpanda }
```
This **fails loud** — the dir exists only on the mounted SSD, so if the SSD ever fails to mount the
container won't start (rather than silently writing to the nvme root). The dir is owned `101:101`.

## Security / auth
- **Internal-network trust** for now (no SASL) — exactly QuestDB's ILP posture. *Never host-publish
  9092/8081/9644.*
- If the Kafka API is ever exposed beyond `data`, enable **SASL/SCRAM** + per-app ACLs and store the
  credentials in **Infisical** (none today).
- Console carries full admin power over an unauthenticated broker → the SSO gate is **mandatory**.

## Secrets
- **None.** Internal-network trust; Console auth is the shared oauth2-proxy. `DOMAIN`, `TZ` only.

## Deploy / recreate
```bash
# from repo root, after scp-ing changed files to /opt/homelab (see CLAUDE.md golden rules)
ssh Jarvis 'cd /opt/homelab && docker compose -f compose.yml up -d redpanda redpanda-console'
```
Compose changes only take effect on a service recreate; drive the aggregate `compose.yml`.
