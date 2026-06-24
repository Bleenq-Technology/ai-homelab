# Node Exporter
**Purpose:** Exposes host-level (OS/hardware) metrics — CPU, memory, disk, network — for Prometheus.
**URL:** internal / no UI
**Auth:** none (internal-only, not exposed via Traefik)
**Image:** prom/node-exporter:v1.11.1
**Networks / data:** `monitoring`; read-only host bind mount `/:/host:ro,rslave`

## Setup as deployed
- Runs with `pid: host` and `--path.rootfs=/host`, mounting the host root read-only at `/host` so it reports the real host's metrics rather than the container's.
- Only on the `monitoring` network; scraped by Prometheus as the `node-exporter` target. No Traefik route.
- **Extra collector enabled** beyond the defaults: `--collector.processes` (per-state process /
  PID-pressure counts; reads `/proc` via `pid: host`, no extra mount). Defaults already cover
  cpu / diskstats (disk I/O) / filesystem (usage) / hwmon (CPU + NVMe + board temps, fan RPM) /
  meminfo / netdev.
- **`--collector.interrupts` was tried and removed** — under this containerized `pid: host`
  setup it fails every scrape (`"couldn't get interrupts: interrupts empty"`,
  `node_scrape_collector_success{collector="interrupts"}=0`), spamming logs for a
  high-cardinality nice-to-have. Other opt-ins left off: `--collector.tcpstat`,
  `--collector.ethtool`, `--collector.softirqs`.
- **Drive wear/SMART is NOT here** — node-exporter's hwmon gives drive *temperature* but not
  endurance/health. That's `smartctl-exporter` (see ../smartctl-exporter/README.md).

## Fixes & gotchas
- `pid: host` and the `rslave` root mount are required for accurate host filesystem/process metrics.

## Secrets
- None. No env keys consumed.
- Nothing sensitive is committed; real values live in `/opt/homelab/.env` (gitignored).
