# Storage tiering plan — jarvis (nvme + SATA SSD)

**Status:** proposed 2026-06-24 · **data stores executed 2026-06-28**; **backups dir 2026-07-09**;
**Phases 1 & 3 measured and declined 2026-07-09** (see Execution log + the verdict below). The
plan is effectively **closed** — reopen only if root fills. Migration was staged and reversible.

## Execution log
- **2026-06-28 — QuestDB, ClickHouse, MinIO moved NVMe → `/srv/ai-data` (SATA SSD).** Method per
  this doc (stop → `rsync -aHAX` → repoint bind → recreate → verify), each verified
  **checksum-identical** + functionally (QuestDB ready; ClickHouse all Langfuse tables; MinIO serves
  objects). Compose: [`docker/data/compose.data.yml`](../docker/data/compose.data.yml). New paths:
  - QuestDB → `/srv/ai-data/marketdata/questdb` (named vol `homelab_questdb_data` → bind; owner 10001)
  - ClickHouse → `/srv/ai-data/telemetry/clickhouse` (owner 101)
  - MinIO → `/srv/ai-data/object-store` (owner 0:1003 root:homelab)
  - **QuestDB promoted from "Phase 3 optional" to done-first** — it's the market-data firehose for the
    `markets-backtesting` / market-data buildout; ingest now lands on the 2 TB SSD from the start.
  - **Old NVMe sources kept for a grace period** — removal commands in host
    `local-notes/STORAGE-TIERING-CLEANUP.md` (run after a few days healthy).
- Already on SSD (greenfield): **Redpanda** (`/srv/ai-data/streaming/redpanda`).
- **2026-07-09 — backups dir moved `/opt/homelab/backups` → `/srv/ai-data/backups`** (the last
  Phase-2 item; it was the single largest nightly write still landing on the nvme). `backup.sh`
  now defaults `BK=/srv/ai-data/backups` and **refuses to run if `/srv/ai-data` isn't mounted**
  rather than silently refilling the root. `/opt/homelab/backups` is a **symlink** to the new
  path so any stale reference keeps working; the `sanctioned` crontab log path was updated.
  Old tree left at `/opt/homelab/backups.old` (24 G) for a grace period — delete once healthy.
  - Verified by a full `backup.sh` run: pg 306 M, ch 45 M, questdb 3.7 M, minio 54 M, homarr
    2.4 M, restic → NAS OK.
  - The 20 G of legacy `clickhouse-*.zip` were **not** copied: 97% of each was ClickHouse's own
    `system` log tables, now excluded from `BACKUP ALL` (see below). Restic still holds the history.
- **2026-07-09 — ClickHouse footprint cut 6.4 G → 544 M.** Its `system.*_log` tables had **no TTL**
  and had grown to 5.65 GiB (97% of its data). Bounded via `data/clickhouse/config/logs-ttl.xml`;
  Langfuse traces given a 14-day TTL. Nightly ClickHouse dump: **3.3 G → 45 M**.
- **2026-07-09 — MinIO's `backups` bucket pruned 20 GiB → 2 GiB.** It was holding the same fat
  legacy `clickhouse-*.zip` copies (`backup.sh` mirrors each dump into the bucket). Note MinIO
  deletes asynchronously via `.minio.sys/tmp/.trash` — `df` doesn't move for a few minutes.
  Langfuse's event blobs turned out to be only **947 M**, not the bulk. `/srv/ai-data`: 34 G → 17 G.
- **2026-07-09 — backup freshness is now alerted.** `backup.sh` publishes `homelab_backup_*`
  through node-exporter's textfile collector (`/var/lib/node_exporter/textfile`); rules
  `BackupStale` / `BackupVeryStale` / `BackupMetricsMissing` / `BackupComponentFailed`. This closes
  the hole the 2026-07-04 power cycle exposed: a backup that never *ran* looked identical to a
  healthy one.
- **2026-07-09 — orphan `homelab_questdb_data` named volume removed** (QuestDB has been on a bind
  since 2026-06-28; the volume was 13 M of stale data attached to nothing).

## Phases 1 & 3 — measured, and DECLINED (2026-07-09)

Both phases existed to serve two goals: nvme **write-wear** and **thermal** relief. Measured on
jarvis, neither goal is real, so **don't do this work** — it would trade live risk for nothing.

| Evidence | Value |
|---|---|
| nvme `smartctl_device_percentage_used` | **0 %** |
| nvme lifetime written | **0.93 TB** of a **600 TBW** rating (~0.15 % consumed) |
| nvme write rate | **~35 GB/day** (172.6 GB over 4.9 d uptime, `/proc/diskstats`) |
| → projected endurance | **~47 years** (≈15 even at 3× write amplification) |
| nvme temperature | **37 °C** (SATA SSD: 29 °C) — cool despite the 3090's airflow |
| root free space | **666 GB** (24 % used) |

- **Phase 1 (models, ~23 G) — no.** Reads don't wear flash, so by this doc's own logic the
  endurance gain is *zero*; the only gain is 23 G on a drive with 666 G free. The cost is real:
  nvme ~7 GB/s vs SATA ~550 MB/s, so every cold load (ComfyUI's 6.9 G SDXL ckpt, the Qwen3-8B
  GGUF) gets ~13× slower. And it walks straight into two known landmines — ComfyUI's
  `1001:1001` ownership crash-loop and the unsloth `HF_HOME` override. Risk for no benefit.
  *This flips only if root fills* — then it's a pure space play and models are the right target.
- **Phase 3 (Prometheus 1.9 G + Loki 1.1 G) — no, and for a sharper reason.** They are genuine
  continuous writers, but a rounding error against an endurance budget 0.15 % consumed. Worse,
  binding them to `/srv/ai-data` makes **monitoring depend on that mount**. jarvis has no UPS yet
  and takes unplanned power cycles; a bad mount after a reboot would take out exactly the
  Prometheus/Loki that tell you something is wrong. Redpanda and `backup.sh` fail loud on that
  mount *by design* — silently writing to the wrong disk is worse than not running — but
  monitoring should degrade, not die. (Phase 3's QuestDB item was done in June; its orphan volume
  is now removed.)

The two moves that actually mattered — **ClickHouse** (2026-06-28) and the **backups dir**
(2026-07-09) — are already banked. That was the whole win.

- **Remaining follow-ups:** ~~Prometheus alert on `/srv/ai-data` fill~~ (generic `DiskSpaceLow`
  covers it; ClickHouse tripwires added 2026-07-09); ~~`backup.sh` path updates~~ (done);
  ~~backup freshness alert~~ (done); QuestDB time-partition TTLs once ingest begins.

> Note: the host doc `local-notes/SSD-2TB-EXPANSION-PLAN.md` (2026-06-17) is **superseded** — it
> assumed a 238 GB NVMe and a separate `/mnt/marketdata` disk. Reality after the drive clone + SSD
> add: one 990 PRO 1 TB (`/`) + the 870 EVO 2 TB (`/srv/ai-data`). Its good ideas (QuestDB TTLs,
> ClickHouse tiered hot/cold, the `/srv/ai-data` alert) are folded into the follow-ups above.

## The two drives
| Drive | Device → mount | Size / used | Speed | Endurance | Role |
|---|---|---|---|---|---|
| **Samsung 990 PRO 1TB** (nvme) | `nvme0n1` → `/` (LVM ext4) | 913 G, **21% used** (697 G free) | ~7 GB/s | ~600 TBW | OS, Docker, hot DBs |
| **Samsung 870 EVO 2TB** (SATA) | `sda1` → **`/srv/ai-data`** (ext4, `UUID=984657ba…`) | 1.8 T, **~empty** (1.7 T free) | ~550 MB/s | ~1200 TBW | bulk models, object store, backups, heavy-write telemetry |

The 990 PRO sits in the airflow path **above the 3090** (hot). It's a high-endurance drive, so this isn't urgent — but moving sustained **writes** off it (a) reduces flash wear and (b) lowers its thermal load, both extending its life. Space is *not* the driver (root is only 21% full); the goals are **write-wear/thermal relief** and **using the empty fast SSD**.

## Principle: what belongs on which tier
- **Stay on nvme** — latency-sensitive + moderate-write: **OS**, **`/var/lib/docker`** (images/layers), **Postgres** (OLTP/WAL), **Redis**, **Qdrant** (RAG vector search). Fast path matters; write volume is modest.
- **Move to SSD** — two kinds:
  - **Bulk read-mostly** (no wear concern; frees nvme + keeps root lean/recloneable): **all AI models** (ComfyUI, unsloth/HF cache, bge-m3, Piper/Whisper voices).
  - **Heavy/append writes** (the real wear + thermal win): **nightly backups**, **MinIO object store**, **ClickHouse** (Langfuse traces), and *optionally* the telemetry TSDBs (**Prometheus/Loki/QuestDB**).

> Reads don't wear flash — moving *models* helps space/leanness, not endurance. Moving *writes* (backups/MinIO/ClickHouse/telemetry) is what extends nvme life. Both are called out below so the rationale is honest.

## Inventory & decision
| Service / data | Host path | Size | Mount type | Write profile | Decision |
|---|---|---|---|---|---|
| ComfyUI models+data | `/opt/homelab/ai/comfyui` | 13 G | bind | low (read-mostly; sdxl 6.9 G) | **→ SSD** (space) |
| unsloth HF model cache | `/opt/unsloth/.cache/huggingface` | 7.8 G | host (HF cache) | low (read-mostly) | **→ SSD** (space) |
| bge-m3 model | `/opt/homelab/ai/bge-m3` | 606 M | bind | low | **→ SSD** (space) |
| Piper / Whisper voices | `/opt/homelab/ai/wyoming-*` | 432 M | bind | low | **→ SSD** (space) |
| **Backups** (nightly dumps) | `/opt/homelab/backups` | 9.6 G | bind | **high** (~10–15 G written/night) | **→ SSD** (wear ★) |
| **MinIO** object store | `/opt/homelab/data/minio` | 8.7 G | bind | med-high (artifacts + nightly tar) | **→ SSD** (wear ★) |
| **ClickHouse** (Langfuse traces) | `/opt/homelab/data/clickhouse` | 2.5 G | bind | **high** (continuous) | **→ SSD** (wear ★) |
| **Redpanda** (event spine log) | `/srv/ai-data/streaming/redpanda` | new | bind-backed vol | **high** (continuous append) | **already on SSD** (greenfield, no migration) ★ |
| Prometheus TSDB | `homelab_prometheus_data` (vol) | 892 M | named vol | high (continuous) | **→ SSD (optional, Phase 3)** |
| Loki logs | `homelab_loki_data` (vol) | 522 M | named vol | high | **→ SSD (optional, Phase 3)** |
| QuestDB | `homelab_questdb_data` (vol) | 47 M | named vol | med-high | **→ SSD (optional, Phase 3)** |
| Neo4j (GraphRAG) | `/opt/homelab/ai/neo4j` | 517 M | bind | med | optional → SSD |
| OpenWebUI app data | `/opt/homelab/ai/openwebui` | 1.1 G | bind | med (SQLite/uploads) | keep (UI latency) — borderline |
| **Postgres** | `homelab_postgres_data` (vol) | 928 M | named vol | med (WAL) | **keep nvme** (OLTP latency) |
| Redis | `/opt/homelab/data/redis` | 2.2 M | bind | low disk | keep nvme |
| Qdrant | `/opt/homelab/ai/qdrant` | 105 M | bind | low-med | keep nvme (RAG latency) |
| `/var/lib/docker` (images) | nvme | ~51 G | — | med (pulls/builds) | keep nvme |

★ = primary nvme-longevity win.

**Web project (`web-app`)**: fully **stateless** — `read_only` rootfs, `tmpfs:/tmp`, no persistent volumes; cloudflared is an outbound tunnel. **Nothing to move.**

## Target layout on `/srv/ai-data`
```
/srv/ai-data/
  models/
    comfyui/        # was /opt/homelab/ai/comfyui (basedir+run)
    hf/             # was /opt/unsloth/.cache/huggingface  (HF_HOME)
    bge-m3/         # was /opt/homelab/ai/bge-m3
    piper/  whisper/
  object-store/     # was /opt/homelab/data/minio
  streaming/
    redpanda/       # Redpanda event-spine log (greenfield — placed here from day one)
  backups/          # was /opt/homelab/backups
  telemetry/
    clickhouse/     # was /opt/homelab/data/clickhouse
    prometheus/ loki/ questdb/   # Phase 3 (named-vol conversions)
```

## Migration method (per service — safe, reversible)
**Golden rules:** one service at a time; never delete the source until the service is verified healthy on the new path; **preserve ownership/ACLs** (`rsync -aHAX`) — several dirs have service-specific uid/gid (ComfyUI `1001:1001`, ClickHouse `101`, MinIO/Postgres uids) and we just got burned by ownership drift.

### A) Bind-mounted dirs (ComfyUI, MinIO, ClickHouse, backups, models, …)
```bash
cd /opt/homelab
SRC=/opt/homelab/data/minio ; DST=/srv/ai-data/object-store          # example
docker compose -f compose.yml stop minio
sudo mkdir -p "$DST"
sudo rsync -aHAX --info=progress2 "$SRC/" "$DST/"
sudo diff -rq "$SRC" "$DST" | head                                    # verify identical
#   edit the bind source in the compose file, e.g. data/compose.data.yml:
#     - ./data/minio:/data    →    - /srv/ai-data/object-store:/data
docker compose -f compose.yml up -d minio
#   verify healthy (logs, endpoint), THEN after a grace period:
sudo rm -rf "$SRC"
```
*Rollback:* revert the compose line + `up -d` (source dir still present until the final `rm`).

### B) Named volumes (Phase 3: Prometheus / Loki / QuestDB)
Convert to a bind-backed local volume on the SSD (rename so compose creates it fresh):
```yaml
volumes:
  prometheus_data_ssd:
    driver: local
    driver_opts: { type: none, o: bind, device: /srv/ai-data/telemetry/prometheus }
```
```bash
docker compose -f compose.yml stop prometheus
sudo mkdir -p /srv/ai-data/telemetry/prometheus
sudo rsync -aHAX /var/lib/docker/volumes/homelab_prometheus_data/_data/ /srv/ai-data/telemetry/prometheus/
#   point the prometheus service at prometheus_data_ssd, then:
docker compose -f compose.yml up -d prometheus
#   verify, then: docker volume rm homelab_prometheus_data
```

### C) unsloth HF cache (host systemd service)
```bash
sudo systemctl stop unsloth-studio
sudo mkdir -p /srv/ai-data/models/hf
sudo rsync -aHAX /opt/unsloth/.cache/huggingface/ /srv/ai-data/models/hf/
#   add to /etc/systemd/system/unsloth-studio.service.d/override.conf:
#     Environment=HF_HOME=/srv/ai-data/models/hf
sudo systemctl daemon-reload && sudo systemctl start unsloth-studio
#   confirm it serves (no re-download) on :8888, then rm the old cache
```

## Phased execution (recommended order)
- **Phase 0 — prep (no downtime):**
  - Fix the **stale fstab line** `UUID=  /srv/ai-data …` (empty UUID — remove it; the real `UUID=984657ba…` line stays).
  - Set base perms: `sudo chown root:homelab /srv/ai-data && sudo chmod 2775 /srv/ai-data` (group-manageable, setgid — matches the homelab convention; service subdirs keep their own uid/gid).
  - (Optional) stop ComfyUI's per-boot pip churn (it wrote 6.3 G to the nvme overlay across today's restarts) — pin `USE_PIPUPGRADE`/clone behavior in its compose env.
- **Phase 1 — models (read-mostly, lowest risk):** ComfyUI, unsloth HF cache, bge-m3, Piper, Whisper. Frees ~22 G off nvme; zero write-wear concern. → **DECLINED 2026-07-09**, see the verdict above.
- **Phase 2 — heavy writers (the longevity win):** backups dir, MinIO, ClickHouse. Removes the largest nightly write burst + continuous trace writes from the nvme. → **DONE** (ClickHouse + MinIO 2026-06-28; backups dir 2026-07-09).
- **Phase 3 — optional telemetry:** Prometheus, Loki, QuestDB (named-volume conversions) for maximum nvme write/thermal relief. Lower priority given the 990 PRO's endurance. → **QuestDB done 2026-06-28; Prometheus/Loki DECLINED 2026-07-09**, see the verdict above.

## Stays on nvme (and why)
OS · `/var/lib/docker` · **Postgres** (OLTP latency, app-critical) · **Redis** · **Qdrant** (RAG latency). These are latency-sensitive with only moderate write volume; nvme is the right home.

## After execution
- Update each moved service's bind path in its compose file (`ai/compose.ai.yml`, `data/compose.data.yml`, `monitoring/…`) and commit — the repo stays the source of truth.
- Note the tiering in `docker/README.md` and the relevant service READMEs.
- Re-verify the full stack health and that `/srv/ai-data` auto-mounts cleanly on a reboot (it's `nofail` + by-UUID).
