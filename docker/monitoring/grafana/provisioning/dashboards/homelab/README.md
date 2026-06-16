# Grafana dashboards (provisioned)

Auto-loaded from this folder by the `Homelab` dashboard provider
([../dashboards.yml](../dashboards.yml)) into the **Homelab** folder in Grafana. Files here are the
source of truth — edit the JSON and Grafana reloads it (changes made in the UI are not persisted
back). All panels query the **Prometheus** datasource (pinned `uid: prometheus` in
[datasources.yml](../../datasources/datasources.yml) so references resolve on a fresh provision).

| Dashboard | uid | What it shows | Source data |
|-----------|-----|---------------|-------------|
| **Jarvis — Overview (Host & GPU)** | `jarvis-overview` | Single pane of glass: CPU %, memory %, GPU %, VRAM % gauges; load, disk, GPU temp/power; CPU/mem/net/disk and GPU util/VRAM time series | `node-exporter`, `nvidia_smi` |
| **GPU — RTX 3090** | `jarvis-gpu` | GPU deep-dive: utilisation, VRAM used/free/total, temperature, power, fan, core/SM/memory clocks | `nvidia-gpu-exporter` |
| **Service Traffic (Traefik)** | `jarvis-traffic` | Per-service request rate, p95 latency, status codes, error rates (OpenWebUI, LiteLLM, Langfuse, …) | `traefik` metrics |
| **Node Exporter Full** | `rYdddlPWk` | Comprehensive host deep-dive (CPU, memory, disk, filesystem, network, processes) | `node-exporter` |
| **Docker Monitoring** | _(existing)_ | Per-container CPU/memory/network | `cadvisor` |

## Metric sources

- **Host** — `node-exporter` (`job=node`), already scraped. CPU/mem/disk/network/load. No Telegraf
  needed; node-exporter is the Prometheus-native equivalent.
- **GPU** — `nvidia-gpu-exporter` (`utkuozdemir/nvidia_gpu_exporter`, `job=nvidia-gpu`), added in
  [compose.monitoring.yml](../../../compose.monitoring.yml). Exposes `nvidia_smi_*` (util, VRAM,
  temp, power, fan, clocks) for the RTX 3090.
  - **Gotcha:** AUTO field discovery panics on newer nvidia-smi fields like
    `clocks_event_reasons_counters.sync_boost [us]` (invalid Prometheus metric name). Fixed by
    pinning an explicit `--query-field-names=...` list (see the compose service).
- **Service traffic** — `traefik` metrics entrypoint (`traefik_service_*`), already scraped.
- **Containers** — `cadvisor` (`container_*`), already scraped.

## LLM / AI observability

LiteLLM's Prometheus `/metrics` emission is **gated behind an enterprise license** — the OSS build
loads the `prometheus` callback (logs "Initialized") but emits nothing, so there's no LiteLLM
Grafana dashboard. Instead:

- **Langfuse** (`langfuse.pdx.sanctioned.tech`) is the LLM analytics surface — every OpenWebUI /
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
