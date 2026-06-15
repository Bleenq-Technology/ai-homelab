# AdGuard Exporter
**Purpose:** Exposes AdGuard Home DNS/query metrics for Prometheus.
**URL:** internal / no UI
**Auth:** none on the exporter itself (it authenticates *to* AdGuard); not exposed via Traefik
**Image:** ebrianne/adguard-exporter:latest
**Networks / data:** `proxy`, `monitoring`; no volumes

## Setup as deployed
- Reaches AdGuard over HTTP: `ADGUARD_PROTOCOL=http`, `ADGUARD_HOSTNAME=adguard`, `ADGUARD_PORT=80`.
- Logs into AdGuard using `ADGUARD_USERNAME` (default `admin`) and `ADGUARD_PASSWORD` (default `change_me_adguard`).
- On `proxy` (to reach the `adguard` service) and `monitoring` (scraped by Prometheus as the `adguard-exporter` target).

## Fixes & gotchas
- `ADGUARD_USERNAME` / `ADGUARD_PASSWORD` **must match the credentials set in AdGuard's setup wizard** — otherwise login fails and no metrics are produced.
- Image is pinned to `:latest` (upstream publishes no stable semver tag here); pin a digest if reproducibility is needed.

## Secrets
- `ADGUARD_USERNAME`, `ADGUARD_PASSWORD` — AdGuard login used by the exporter.
- Nothing sensitive is committed; real values live in `/opt/homelab/.env` (gitignored).
