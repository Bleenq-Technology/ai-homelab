# Infisical
**Purpose:** Secrets management — intended future secrets backend for this stack.
**URL:** https://infisical.pdx.sanctioned.tech
**Auth:** local login (account created on first visit)
**Image:** infisical/infisical:latest-postgres
**Networks / data:** `proxy` + `data` (external); no bind mount (state in Postgres/Redis)

## Setup as deployed
- Routed via Traefik: `Host(infisical.${DOMAIN})`, `websecure`, `tls=true`, `secure-chain@file`; service port `8080`.
- Postgres DB `infisical` via `DB_CONNECTION_URI` (`postgresql://infisical:${INFISICAL_DB_PASSWORD}@postgres:5432/infisical`).
- Redis DB 1 via `REDIS_URL` (`redis://:${REDIS_PASSWORD}@redis:6379/1`).
- `SITE_URL: https://infisical.${DOMAIN}`; `TZ` from `.env`.
- First login: create the initial account through the web UI.

## Fixes & gotchas
- None recorded. (Not yet adopted as the active secrets backend — currently `.env` + Docker secrets are used.)

## Secrets
- `.env` keys: `INFISICAL_DB_PASSWORD`, `REDIS_PASSWORD`, `INFISICAL_ENCRYPTION_KEY` (defaults to a placeholder if unset), `INFISICAL_AUTH_SECRET` (defaults to a placeholder if unset), `DOMAIN`, `TZ`.
- The defaulted `ENCRYPTION_KEY` / `AUTH_SECRET` placeholders must be overridden with real values in `.env` before real use.
- Nothing sensitive is committed to git.
