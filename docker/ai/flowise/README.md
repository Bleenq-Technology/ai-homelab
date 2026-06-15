# Flowise
**Purpose:** LLM workflow builder.
**URL:** https://flowise.pdx.sanctioned.tech
**Auth:** local login (username/password)
**Image:** flowiseai/flowise:2.2.4
**GPU:** no
**Networks / data:** proxy, ai; bind mount `./flowise/data` -> `/root/.flowise`

## Setup as deployed
- Local login credentials:
  - `FLOWISE_USERNAME=${FLOWISE_USERNAME}`
  - `FLOWISE_PASSWORD=${FLOWISE_PASSWORD}`
- `FLOWISE_SECRETKEY_OVERWRITE=${FLOWISE_SECRETKEY}` — fixed encryption key for stored credentials.
- Data persists under `./flowise/data` (`/root/.flowise`).
- Traefik router on `websecure`, TLS, middleware `secure-chain@file`, backend port 3000.

### First login
- Log in with `FLOWISE_USERNAME` / `FLOWISE_PASSWORD`.

## Fixes & gotchas
- OIDC/SSO is a **paid** Flowise feature, so we stay on **local login**.

## Secrets
- `FLOWISE_USERNAME`, `FLOWISE_PASSWORD` — local login.
- `FLOWISE_SECRETKEY` — credential encryption key (`FLOWISE_SECRETKEY_OVERWRITE`); keep stable.
- `TZ`. All secrets come from `/opt/homelab/.env` (gitignored); nothing sensitive is committed.
