# Promtail
**Purpose:** Log shipper — tails host and Docker container logs and pushes them to Loki.
**URL:** internal / no UI
**Auth:** none (internal-only, not exposed via Traefik)
**Image:** grafana/promtail:3.3.2
**Networks / data:** `monitoring`; read-only bind mounts `/var/log`, `/var/lib/docker/containers`, and `./promtail:/etc/promtail` (config)

## Setup as deployed
- Started with `-config.file=/etc/promtail/promtail.yml` (config from `promtail/promtail.yml`).
- Mounts `/var/log:ro` (host logs) and `/var/lib/docker/containers:ro` (per-container JSON logs), both read-only.
- Only on the `monitoring` network; pushes scraped logs to `loki` over that network.

## Fixes & gotchas
- None.

## Secrets
- None. No env keys consumed.
- Nothing sensitive is committed; real values live in `/opt/homelab/.env` (gitignored).
