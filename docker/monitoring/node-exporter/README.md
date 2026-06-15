# Node Exporter
**Purpose:** Exposes host-level (OS/hardware) metrics — CPU, memory, disk, network — for Prometheus.
**URL:** internal / no UI
**Auth:** none (internal-only, not exposed via Traefik)
**Image:** prom/node-exporter:v1.8.2
**Networks / data:** `monitoring`; read-only host bind mount `/:/host:ro,rslave`

## Setup as deployed
- Runs with `pid: host` and `--path.rootfs=/host`, mounting the host root read-only at `/host` so it reports the real host's metrics rather than the container's.
- Only on the `monitoring` network; scraped by Prometheus as the `node-exporter` target. No Traefik route.

## Fixes & gotchas
- `pid: host` and the `rslave` root mount are required for accurate host filesystem/process metrics.

## Secrets
- None. No env keys consumed.
- Nothing sensitive is committed; real values live in `/opt/homelab/.env` (gitignored).
