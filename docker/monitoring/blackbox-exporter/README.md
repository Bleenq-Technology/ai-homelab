# Blackbox Exporter
**Purpose:** Probes external/HTTPS endpoints (reachability, TLS, status) so Prometheus can alert on availability.
**URL:** internal / no UI
**Auth:** none (internal-only, not exposed via Traefik)
**Image:** prom/blackbox-exporter:v0.25.0
**Networks / data:** `monitoring`; read-only config bind mount `./blackbox-exporter/config:/config:ro`

## Setup as deployed
- Started with `--config.file=/config/blackbox.yml` and `--web.listen-address=:9115`.
- Probe modules are defined in `blackbox-exporter/config/blackbox.yml`.
- Prometheus drives the probes: it targets the HTTPS endpoints and uses Blackbox as the relabel proxy. Only on the `monitoring` network; no Traefik route.

## Fixes & gotchas
- None.

## Secrets
- None. No env keys consumed.
- Nothing sensitive is committed; real values live in `/opt/homelab/.env` (gitignored).
