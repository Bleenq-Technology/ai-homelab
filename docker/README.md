# Homelab Docker stack (`jarvis`)

Unified Docker Compose stack for the homelab, split into four modular layers and
unified by a root [compose.yml](compose.yml) via Compose `include:`. All services
sit behind Traefik v3 with a single **EasyDNS DNS-01 wildcard** cert for
`*.pdx.sanctioned.tech`.

```
docker/
├── compose.yml            # root — includes the four layers below
├── .env.example           # copy to .env and fill in (gitignored)
├── secrets/               # EasyDNS API token/key (gitignored) — see secrets/README.md
├── core/        compose.core.yml        traefik, keycloak, portainer, infisical, firezone, adguard, netbox
├── data/        compose.data.yml        postgres, redis, minio, clickhouse, baserow, pgadmin
├── monitoring/  compose.monitoring.yml  prometheus, grafana, loki, promtail, alertmanager, exporters, watchtower, uptime-kuma
└── ai/          compose.ai.yml          openwebui, n8n, comfyui, wyoming TTS/STT, jupyter, flowise, qdrant, neo4j, searxng, langfuse
```

## Design contract (every service follows this)

- **Networks** (all external, created once): `proxy` is the edge — Traefik plus
  anything with a web route attaches here. `data` / `ai` / `monitoring` are the
  internal segments. A service joins only the networks it actually needs.
- **TLS** is set once on the `websecure` entrypoint (wildcard cert), so a routed
  service needs only: `traefik.enable`, a `Host()` rule, `entrypoints=websecure`,
  `tls=true`, and the shared `secure-chain@file` middleware. No per-service
  `certresolver` label.
- **Secrets**: EasyDNS API creds via Docker secrets (`_FILE` convention). Other
  credentials via `.env`. Postgres provisions one DB + least-privilege role per
  service on first boot ([data/postgres/init](data/postgres/init)).
- **Images are pinned.** Bump deliberately; Watchtower only updates containers you
  explicitly label.

## First-time deploy on jarvis

```bash
# 0. Switch to the jarvis Docker context
docker context use jarvis      # or prefix every command with: docker --context jarvis ...

# 1. Create the shared external networks (once)
for n in proxy data ai monitoring; do docker network create "$n" 2>/dev/null || true; done

# 2. Configure environment + secrets
cp docker/.env.example docker/.env       # then edit: set DOMAIN already correct, fill passwords
#   EasyDNS API creds (see docker/secrets/README.md):
printf '%s' 'YOUR_EASYDNS_TOKEN' > docker/secrets/easydns_token
printf '%s' 'YOUR_EASYDNS_KEY'   > docker/secrets/easydns_key
#   Traefik dashboard hash:
htpasswd -nbB admin 'yourpass'           # paste into TRAEFIK_DASHBOARD_AUTH (double every $ -> $$)

# 3. Bring it up (data layer first lets Postgres/MinIO be ready for consumers)
docker compose -f docker/compose.yml up -d postgres redis minio minio-init clickhouse
docker compose -f docker/compose.yml up -d

# 4. Watch cert issuance on the first run
docker compose -f docker/compose.yml logs -f traefik
```

Bring a single layer up/down without touching the others:

```bash
docker compose -f docker/ai/compose.ai.yml up -d
docker compose -f docker/monitoring/compose.monitoring.yml restart grafana
```

## DNS & firewall

- Point an A record for the homelab (and `*.pdx.sanctioned.tech` or per-host
  records) at jarvis. The wildcard **cert** is issued via the EasyDNS API, but
  **traffic routing** still needs DNS pointing names at this host.
- DNS-01 means port 80 does **not** need to be internet-reachable for certs —
  jarvis only needs outbound access to `rest.easydns.net`.
- Published host ports: `80/443` (Traefik), `53` (AdGuard DNS), `51820/udp`
  (Firezone WireGuard), `7687` (Neo4j Bolt), `10200`/`10300` (Wyoming TTS/STT),
  `3000` (AdGuard first-run setup — can be closed after).

## Notes / follow-ups

- **GPU**: `comfyui`, `wyoming-piper`, `wyoming-faster-whisper` request the NVIDIA
  runtime — install `nvidia-container-toolkit` on jarvis.
- **ComfyUI image** is a community build (`ghcr.io/ai-dock/comfyui`) — confirm or
  swap for your preferred one.
- **Wyoming** services speak the Wyoming TCP protocol (for Home Assistant), so
  they are published as raw TCP ports, not routed through Traefik.
- **SSO**: Keycloak is deployed; wiring Grafana/n8n/Firezone/dashboard OIDC clients
  is a follow-up pass (replace the dashboard `basicauth` with a Keycloak
  forward-auth middleware).
- **Secrets backend**: Infisical is deployed but not yet the source of truth —
  the plan is to migrate `.env` values into it later.
