# Prometheus
**Purpose:** Time-series metrics collection and alert rule evaluation for the homelab.
**URL:** https://prometheus.pdx.sanctioned.tech
**Auth:** Keycloak forward-auth (`secure-sso@file` middleware)
**Image:** prom/prometheus:v3.1.0
**Networks / data:** `proxy`, `monitoring`; config bind mount `./prometheus:/etc/prometheus:ro`, TSDB on named volume `prometheus_data:/prometheus`

## Setup as deployed
- Started with `--config.file=/etc/prometheus/prometheus.yml`, `--storage.tsdb.path=/prometheus`, the console library/template paths, and `--web.enable-lifecycle` (allows config reload via API).
- `depends_on: [alertmanager]` — alerts are forwarded to Alertmanager.
- Exposed on container port 9090; Traefik routes `prometheus.${DOMAIN}` over `websecure` with TLS, gated by `secure-sso@file` (Keycloak forward-auth).
- Config lives under `prometheus/`: `prometheus.yml` (scrape + alerting config) and `alert_rules.yml` (alerting rules).
- Scrape targets: `traefik:8082`, `cadvisor`, `node-exporter`, `postgres-exporter`, `minio` (native `/minio/v2/metrics`), `adguard-exporter`, `watchtower`, `keycloak`, and HTTPS endpoints probed indirectly via the Blackbox Exporter.

## Issues & Fixes

**Symptom:** the original `clickhouse-exporter` (image `f1yegor/clickhouse-exporter`) crash-looped, panicking on startup (`MustRegister` panic).
**Fix:** removed the clickhouse-exporter service entirely; ClickHouse-native Prometheus metrics on `:9363` remains a TODO.

## Secrets
- Prometheus itself needs no secrets. Only `DOMAIN` (Traefik routing) is interpolated for this service.
- Nothing sensitive is committed; real values live in `/opt/homelab/.env` (gitignored).
