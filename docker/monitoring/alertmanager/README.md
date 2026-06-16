# Alertmanager
**Purpose:** Routes and de-duplicates alerts from Prometheus and dispatches notifications **to Discord**.
**URL:** https://alertmanager.pdx.sanctioned.tech
**Auth:** Keycloak forward-auth (`secure-sso@file` middleware)
**Image:** prom/alertmanager:v0.28.0
**Networks / data:** `proxy`, `monitoring`; config bind mount `./alertmanager:/etc/alertmanager:ro`, state on named volume `alertmanager_data:/alertmanager`

## Setup as deployed
- Started with `--config.file=/etc/alertmanager/config.yml` and `--storage.path=/alertmanager`.
- Exposed on container port 9093; Traefik routes `alertmanager.${DOMAIN}` over `websecure` with TLS, gated by `secure-sso@file` (Keycloak forward-auth).
- **Single Discord receiver.** All alerts (except the dead-man's-switch `Watchdog`) route to
  the homelab Discord channel — the same webhook Uptime Kuma uses, so up/down pings and
  metric alerts land together. `send_resolved: true`, so you get a ✅ when an alert clears.
- Alert rules live in [`../prometheus/alert_rules.yml`](../prometheus/alert_rules.yml):
  instance-down, Traefik/endpoint health, **GPU + CPU temperature** (top priority), disk
  usage, host-memory pressure, container OOM-kills / restart-loops, Postgres connection
  saturation, and Redis memory.

## The Discord webhook secret
Alertmanager does **not** expand `${ENV}` in `config.yml`, so the webhook is delivered as a
file and referenced with `webhook_url_file: /run/secrets/discord_webhook_url`:

- **Source of truth:** Infisical key `DISCORD_WEBHOOK_URL` (project `homelab`, env `prod`).
- `pull-secrets.sh` writes it into `/opt/homelab/.env`.
- `compose.monitoring.yml` turns that env var into a Docker secret via the Compose
  `secrets: { discord_webhook_url: { environment: DISCORD_WEBHOOK_URL } }` source — no
  plaintext secret file on disk. Compose strips Infisical's surrounding quotes, so the
  mounted file is a clean URL.

## Test / operate
```bash
# Validate config (override the image entrypoint to reach amtool):
docker run --rm --entrypoint amtool -v $PWD/config.yml:/c.yml:ro prom/alertmanager:v0.28.0 check-config /c.yml
# Fire a one-off test alert straight to the Discord receiver (from any container on the
# monitoring net; auto-resolves in ~5 min):
docker exec telegraf wget -qO- --header='Content-Type: application/json' \
  --post-data='[{"labels":{"alertname":"PipelineSelfTest","severity":"warning"},"annotations":{"summary":"test","description":"pipeline ok"}}]' \
  http://alertmanager:9093/api/v2/alerts
# Apply rule edits without a restart:
docker kill --signal=HUP prometheus          # reloads prometheus.yml + alert_rules.yml
docker compose -f compose.yml up -d alertmanager   # after editing config.yml
```

## Gotchas
- `amtool` is in the image but the entrypoint is `alertmanager`, so validate with
  `--entrypoint amtool` (otherwise: `error: unexpected amtool`).
- `amtool alert add` uses the matcher parser — annotation values with spaces / `->` /
  parens get mangled. Use the `/api/v2/alerts` JSON endpoint for clean test payloads.
- The CPU-temperature rule is scoped to `chip=~"pci.*18_3"` (AMD k10temp) on purpose:
  `node_hwmon_temp_celsius` also exposes the NVMe SSD and a flaky WMI chip that reports a
  bogus 216 °C — a naïve `max()` would fire forever.

## Secrets
- `DISCORD_WEBHOOK_URL` — Discord webhook (Infisical → `.env` → Compose env-sourced secret).
- `DOMAIN` — Traefik routing.
- Nothing sensitive is committed; real values live in Infisical / `/opt/homelab/.env`.
