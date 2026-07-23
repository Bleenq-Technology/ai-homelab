# Grafana dashboards (provisioned)

Auto-loaded from this folder by the `Homelab` dashboard provider
([../dashboards.yml](../dashboards.yml)) into the **Homelab** folder in Grafana. Files here are the
source of truth — edit the JSON and Grafana reloads it (changes made in the UI are not persisted
back). Most panels query the **Prometheus** datasource (pinned `uid: prometheus` in
[datasources.yml](../../datasources/datasources.yml) so references resolve on a fresh provision); the
**Logs (Loki)** dashboard queries the **Loki** datasource (`uid: loki`).

| Dashboard | uid | What it shows | Source data |
|-----------|-----|---------------|-------------|
| **Jarvis — Overview (Host & GPU)** | `jarvis-overview` | Single pane of glass: CPU %, memory %, GPU %, VRAM % gauges; load, disk, GPU temp/power; CPU/mem/net/disk and GPU util/VRAM time series | `node-exporter`, `nvidia_smi` |
| **GPU — RTX 3090** | `jarvis-gpu` | GPU deep-dive: utilisation, VRAM used/free/total, temperature, power, fan, core/SM/memory clocks | `nvidia-gpu-exporter` |
| **Service Traffic (Traefik)** | `jarvis-traffic` | Per-service request rate, p95 latency, status codes, error rates (OpenWebUI, LiteLLM, Langfuse, …) | `traefik` metrics |
| **Node Exporter Full** | `rYdddlPWk` | Comprehensive host deep-dive (CPU, memory, disk, filesystem, network, processes) | `node-exporter` |
| **Containers (Docker)** | `jarvis-containers` | Per-container CPU %, memory, network & block I/O (by name), + a usage table | `telegraf` (docker input) |
| **Postgres** | `jarvis-postgres` | Status, connections vs max, cache-hit ratio, transactions/sec, connections + sizes per database, deadlocks/temp | `postgres-exporter` |
| **Redis** | `jarvis-redis` | Status, memory, clients, ops/sec, keyspace hit ratio, keys per DB, hits/misses, network I/O, evictions | `redis-exporter` |
| **Storage & Drives** | `jarvis-storage` | Filesystem usage; per-device throughput / IOPS / utilisation / latency; drive temps; NVMe life-used / spare / TBW; SMART status & media errors; motherboard hwmon temps & fans | `node-exporter`, `smartctl-exporter` |
| **Logs (Loki)** | `jarvis-logs` | Centralised log search/filter across all containers + host: log-volume-by-service bars, line & error-line counts, a logs panel, an errors-only panel; **Service/container** + **text-filter** variables | `loki` (promtail) |

## Metric sources

- **Host** — `node-exporter` (`job=node`), already scraped. CPU/mem/disk/network/load. No Telegraf
  needed; node-exporter is the Prometheus-native equivalent. Runs with the default collectors plus
  `--collector.processes` and `--collector.interrupts` enabled (see the compose service).
- **Drive SMART** — `smartctl-exporter` (`prometheuscommunity/smartctl-exporter`, `job=smartctl`,
  `smartctl_device_*`), added in [compose.monitoring.yml](../../../../compose.monitoring.yml). Exposes
  per-drive wear/health/temperature for the NVMe + SATA SSD — the signal hwmon can't provide. See
  [../../../../smartctl-exporter/README.md](../../../../smartctl-exporter/README.md).
- **GPU** — `nvidia-gpu-exporter` (`utkuozdemir/nvidia_gpu_exporter`, `job=nvidia-gpu`), added in
  [compose.monitoring.yml](../../../../compose.monitoring.yml). Exposes `nvidia_smi_*` (util, VRAM,
  temp, power, fan, clocks) for the RTX 3090.
  - **Gotcha:** AUTO field discovery panics on newer nvidia-smi fields like
    `clocks_event_reasons_counters.sync_boost [us]` (invalid Prometheus metric name). Fixed by
    pinning an explicit `--query-field-names=...` list (see the compose service).
- **Service traffic** — `traefik` metrics entrypoint (`traefik_service_*`), already scraped.
- **Containers** — `telegraf` (`job=telegraf`, `docker_container_*`), reading the Docker Engine API
  via `docker.sock`. **Replaced cadvisor**, whose Docker factory can't map cgroups → names when
  Docker uses the **containerd image store** (it looks for an overlay2 `layerdb` that doesn't exist,
  spamming "failed to identify read-write layer" and producing nameless series). Telegraf's docker
  input gets per-container CPU/mem/net/blkio **with the friendly `container_name` + compose labels**,
  independent of the storage driver. Needs the host `docker` group (`group_add: ["980"]`) to read
  the socket — adjust the gid (`stat -c %g /var/run/docker.sock`) if rebuilding on another host.
- **Postgres** — `postgres-exporter` (`job=postgres-exporter`, `pg_*`), already scraped. Worth a
  dashboard because it's the shared backbone (Keycloak, NetBox, Infisical, Baserow, Langfuse, n8n…).
- **Redis** — `redis-exporter` (`oliver006/redis_exporter`, `job=redis`, `redis_*`), added in
  [compose.monitoring.yml](../../../../compose.monitoring.yml); reads via `REDIS_PASSWORD`.

> **Deliberately not dashboarded:** **Qdrant** exposes native `/metrics` but it requires an
> `api-key` *header* that Prometheus scrape configs can't send cleanly — not worth it for a leaf
> RAG service. **Baserow** has no Prometheus endpoint; its container CPU/mem is already in the
> Containers dashboard. The principle: dashboard things whose failure *cascades* (Postgres, Redis),
> not every leaf service.

## LLM / AI observability

LiteLLM's Prometheus `/metrics` emission is **gated behind an enterprise license** — the OSS build
loads the `prometheus` callback (logs "Initialized") but emits nothing, so there's no LiteLLM
Grafana dashboard. Instead:

- **Langfuse** (`langfuse.lab.example`) is the LLM analytics surface — every OpenWebUI /
  LiteLLM completion is traced there with prompts, tokens, latency, and cost. Use its own UI.
- **Grafana** covers LLM *traffic* via the **Service Traffic** dashboard (request rate / latency /
  errors for the `openwebui`, `litellm`, `langfuse`, `comfyui` services) and per-container resource
  use via **Docker Monitoring**.

## Adding a catalog dashboard

`node-exporter-full.json` is vendored from grafana.com dashboard **1860**. To refresh or add another:
```bash
curl -sL https://grafana.com/api/dashboards/<ID>/revisions/latest/download \
  | sed 's/${ds_prometheus}/prometheus/g' > <name>.json   # repoint the datasource var to our uid
```
Then drop it in this folder. (The exact datasource variable name varies per dashboard — check with
`grep -oE '"uid": *"\$\{[^}]*\}"'`.)
