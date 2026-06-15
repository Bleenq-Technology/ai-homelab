# Loki
**Purpose:** Log aggregation backend; stores logs shipped by Promtail and is queried through Grafana.
**URL:** internal / no UI
**Auth:** none (internal-only, not exposed via Traefik)
**Image:** grafana/loki:3.3.2
**Networks / data:** `monitoring`; named volume `loki_data:/loki`

## Setup as deployed
- Runs with the image's default config: `-config.file=/etc/loki/local-config.yaml`.
- Only on the `monitoring` network — no Traefik labels, no public route. Accessed internally by Grafana (as a datasource) and written to by Promtail.

## Fixes & gotchas
- None. Stock single-binary config; storage persists to the `loki_data` volume.

## Secrets
- None. No env keys consumed.
- Nothing sensitive is committed; real values live in `/opt/homelab/.env` (gitignored).
