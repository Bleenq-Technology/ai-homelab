# Redis

**Purpose:** Shared cache / queue backend for multiple lab services.
**URL:** internal / no UI
**Auth:** local login (password via `--requirepass`)
**Image:** redis:7.4-alpine
**Networks / data:** `data` network; bind mount `./redis/data` -> `/data`

## Setup as deployed
- Reachable by other stacks at `redis:6379` on the `data` network.
- Started with `redis-server --requirepass ${REDIS_PASSWORD} --save 60 1 --loglevel warning` (password required; RDB persistence: snapshot if >=1 key changed in 60s).
- Consumers share one instance via **logical DB numbers**:
  - `1` = infisical
  - `2` = netbox task / `3` = netbox cache
  - `4` = baserow
  - `5` = langfuse
  - `6` = searxng
- Healthcheck runs `redis-cli -a $REDIS_PASSWORD ping`.

## Fixes & gotchas
- None specific to this service. Persistence is enabled via `--save`; clients must pass the password (and select the correct DB number) or connections are rejected.

## Secrets
- `.env` keys: `REDIS_PASSWORD` (and `TZ`).
- Real values live only in `/opt/homelab/.env` on jarvis (gitignored). Nothing sensitive is committed.
