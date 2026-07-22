# Loki
**Purpose:** Log aggregation backend; stores logs shipped by Promtail and is queried through Grafana.
**URL:** internal / no UI
**Auth:** none (internal-only, not exposed via Traefik)
**Image:** grafana/loki:3.7.2
**Networks / data:** `monitoring`; named volume `loki_data:/loki`

## Setup as deployed
- Config is **vendored** at [`local-config.yaml`](local-config.yaml) (single-file bind mount over
  the image default) and loaded with `-config.file=/etc/loki/local-config.yaml`. It's the image's
  stock single-binary config **plus a `limits_config` block, a `compactor` block (retention), and**
  `analytics.reporting_enabled: false`.
- Only on the `monitoring` network — no Traefik labels, no public route. Accessed internally by Grafana (as a datasource) and written to by Promtail.

## Searching logs (the point of all this)
Logs are explored **in Grafana** (which is itself behind Keycloak OIDC, so that's the access gate —
Loki has no auth of its own by design, being unreachable off the `monitoring` network):
- **Dashboard:** *Homelab → Logs (Loki)* (`jarvis-logs`) — a `service` multi-select (from
  `label_values(container)`) + a free-text `search` regex, log-volume-by-service, error-count stats,
  a live logs panel, and an errors-only panel.
- **Explore:** pick the **Loki** datasource for ad-hoc LogQL. Useful label filters Promtail attaches:
  `{container="..."}`, `{compose_service="..."}`, `{compose_project="..."}`, `{stream="stderr"}`,
  plus `{unit="..."}` for host journald. e.g. `{compose_service="litellm"} |~ "(?i)error"`.

## Retention (30 days)
`limits_config.retention_period: 720h` (= 30d, a whole multiple of the 24h index period Loki
requires) with the **`compactor`** (`retention_enabled: true`, `delete_request_store: filesystem`)
doing the actual deletion. Before this (added 2026-07-20, todos #12) Loki kept logs **forever** — the
store just grew on the SSD (~522 MB and climbing). Change the period in `local-config.yaml` and
restart to adjust. Verify live: `curl http://loki:3100/config | grep retention_period`.

## Secret redaction (Promtail, 2026-07-22)
Some services echo secrets to stdout/journald that we don't control at the source — most notably the
host **`unsloth`** systemd service, whose startup banner prints its API key as `API Key: sk-unsloth-…`
**and** inside example `curl -H "Authorization: Bearer <key>"` lines. Promtail ships journald + syslog
here, and with **30-day retention** those tokens would sit searchable in Grafana for a month.

**Promtail now redacts by shape** at collection time — see the `pipeline_stages` `replace` rules in
[`../promtail/promtail.yml`](../promtail/promtail.yml) (Bearer tokens, `sk-` keys, `api_key=`,
`password=`, `ghp_…`, JWTs, and the password in a `postgres://` DSN). It's defence-in-depth: it catches
this leak **and any future one from any service**, not just the ones we know about. It does **not**
excuse a service logging secrets — fix the source where you can — but the source is often upstream code
we don't own.

**Two gotchas, both found by testing rather than reading docs:**
- Promtail **strict-parses** its config: a shared YAML anchor at top level (`.redact_stages: &x`) is
  rejected with *"field not found in type config.plain"*. The rules are **inlined into all three scrape
  jobs** — edit all three copies.
- Promtail's `replace` substitutes **only the captured group** and leaves the rest of the match intact,
  and there is **no `${N}` templating** (a literal `${1}` gets stored). So each rule captures the
  *secret* as the single group → `<REDACTED>`, keeping the readable prefix (`Bearer`, `sk-`, the DSN
  user) outside the group. Verified live with a canary: `Bearer sk-…`, `password=…` and a DSN password
  were stored redacted while a benign `risk-assessment asterisk` line was untouched (the `\bsk-` word
  boundary is what avoids the `risk-`/`asterisk-` false positives).

**Purging what already leaked:** redaction only affects *new* lines. Existing leaked tokens were removed
with Loki's **delete API** (enabled by the compactor + `delete_request_store`), which the retention
config already provides:
```bash
curl -s -XPOST -G http://loki:3100/loki/api/v1/delete \
  --data-urlencode 'query={job="varlogs"} |~ `Bearer [A-Za-z0-9._-]{20,}`' \
  --data-urlencode "start=$(($(date +%s)-2592000))" --data-urlencode "end=$(date +%s)"   # -> 204
curl -s http://loki:3100/loki/api/v1/delete    # list requests; processed after retention_delete_delay (2h)
```

## Fixes & gotchas
- **Ingestion limits bumped (2026-06-26).** Stock defaults (4 MB/s rate, 6 MB burst, tenant `fake`)
  returned **HTTP 429** to Promtail whenever it re-shipped a container's whole backlog on
  (re)discovery — a single 97 MB transfer blew past the cap and stalled ingestion. Raised to
  `ingestion_rate_mb: 16` / `ingestion_burst_size_mb: 32`, plus per-stream `8MB`/`24MB` so one chatty
  container can't be throttled on its own stream. Pair with Promtail's noise-drop pipeline (it cuts
  the steady volume; the limit bump absorbs restart bursts). Image is **distroless** (no shell/`cat`)
  — read its baked config with `docker cp loki:/etc/loki/local-config.yaml -`.
- Storage persists to the `loki_data` volume.
- **Editing `local-config.yaml` needs a real restart, not `compose up`.** The config is a bind mount,
  so `docker compose up -d loki` sees no change in the compose *definition* and leaves the container
  running the old config. Use `docker restart loki` (or `up -d --force-recreate loki`), then confirm
  with `curl http://loki:3100/config` (distroless image — query the endpoint, there's no shell).

## Secrets
- None. No env keys consumed.
- Nothing sensitive is committed; real values live in `/opt/homelab/.env` (gitignored).
