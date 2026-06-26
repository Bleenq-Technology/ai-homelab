# Promtail
**Purpose:** Log shipper — tails host and Docker container logs and pushes them to Loki.
**URL:** internal / no UI
**Auth:** none (internal-only, not exposed via Traefik)
**Image:** grafana/promtail:3.6.11
**Networks / data:** `monitoring`; read-only bind mounts `/var/log`, `/var/run/docker.sock` (Docker
service discovery), and `./promtail:/etc/promtail` (config); `promtail_positions` volume for read offsets

## Setup as deployed
- Started with `-config.file=/etc/promtail/promtail.yml` (config from `promtail/promtail.yml`).
- Mounts `/var/log:ro` (host logs) and `/var/run/docker.sock:ro` — containers are discovered via the
  Docker API (`docker_sd_configs`), which yields clean `container`/`compose_*` labels instead of
  parsing raw `*-json.log` files. Three scrape jobs: host `varlogs`, `docker`, host `systemd-journal`.
- Only on the `monitoring` network; pushes scraped logs to `loki` over that network.

## Fixes & gotchas
- **Noise-reduction drops (2026-06-26).** The `docker` job runs `pipeline_stages` that drop two
  known high-volume / low-value sources, scoped per-container with `match` selectors:
  - **`bge-m3`** (llama.cpp embeddings) — per-request slot churn at INFO (`update_slots: all slots
    are idle`, `slot release`, `srv update: - prompt 0x…`), ~19k lines/hr. Drop regex `^[0-9.]+ I `
    kills INFO and **keeps W/E** (llama.cpp's single-char level token).
  - **`traefik`** — internal health/probe access logs (empty user-agent `"-" "-"` to a `@docker`
    router). Real browser/API traffic has a UA, so user-facing access logs and Traefik's own runtime
    logs (logfmt, no UA field) are kept.
  - **Why drops, not sampling:** deterministic drops of *known* noise keep full fidelity for
    everything else — when something breaks the line you need is still there. Probabilistic sampling
    throws away random lines and is the wrong tool at this scale.
  - Each drop sets `drop_counter_reason`, so discards are visible in
    `logentry_dropped_lines_total{reason=…}` on `:9080/metrics`. Promtail **does not hot-reload** —
    `docker restart promtail` after editing the config (compose won't recreate on a bind-mount
    content change).

## Secrets
- None. No env keys consumed.
- Nothing sensitive is committed; real values live in `/opt/homelab/.env` (gitignored).
