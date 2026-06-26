# Loki
**Purpose:** Log aggregation backend; stores logs shipped by Promtail and is queried through Grafana.
**URL:** internal / no UI
**Auth:** none (internal-only, not exposed via Traefik)
**Image:** grafana/loki:3.7.2
**Networks / data:** `monitoring`; named volume `loki_data:/loki`

## Setup as deployed
- Config is **vendored** at [`local-config.yaml`](local-config.yaml) (single-file bind mount over
  the image default) and loaded with `-config.file=/etc/loki/local-config.yaml`. It's the image's
  stock single-binary config **plus a `limits_config` block** and `analytics.reporting_enabled: false`.
- Only on the `monitoring` network — no Traefik labels, no public route. Accessed internally by Grafana (as a datasource) and written to by Promtail.

## Fixes & gotchas
- **Ingestion limits bumped (2026-06-26).** Stock defaults (4 MB/s rate, 6 MB burst, tenant `fake`)
  returned **HTTP 429** to Promtail whenever it re-shipped a container's whole backlog on
  (re)discovery — a single 97 MB transfer blew past the cap and stalled ingestion. Raised to
  `ingestion_rate_mb: 16` / `ingestion_burst_size_mb: 32`, plus per-stream `8MB`/`24MB` so one chatty
  container can't be throttled on its own stream. Pair with Promtail's noise-drop pipeline (it cuts
  the steady volume; the limit bump absorbs restart bursts). Image is **distroless** (no shell/`cat`)
  — read its baked config with `docker cp loki:/etc/loki/local-config.yaml -`.
- Storage persists to the `loki_data` volume.

## Secrets
- None. No env keys consumed.
- Nothing sensitive is committed; real values live in `/opt/homelab/.env` (gitignored).
