# cAdvisor
**Purpose:** Exposes per-container CPU, memory, network, and filesystem metrics for Prometheus.
**URL:** internal / no UI
**Auth:** none (internal-only, not exposed via Traefik)
**Image:** gcr.io/cadvisor/cadvisor:v0.49.1
**Networks / data:** `monitoring`; host bind mounts only (no named volume)

## Setup as deployed
- Runs `privileged: true` with the `/dev/kmsg` device, required to read full container/host stats.
- Read-only host mounts: `/:/rootfs`, `/var/run`, `/sys`, `/var/lib/docker/`, `/dev/disk/`.
- Only on the `monitoring` network; scraped by Prometheus as the `cadvisor` target. No Traefik route.

## Fixes & gotchas
- Requires `privileged` + `/dev/kmsg`; without them cAdvisor cannot collect complete metrics.

## Secrets
- None. No env keys consumed.
- Nothing sensitive is committed; real values live in `/opt/homelab/.env` (gitignored).
