# Flowise
> ⚠️ **DEPRECATED / parked (2026-06-18).** Flowise was added as the hyped "better-than-n8n" LLM-flow
> builder, but that chatter has faded and it overlaps **n8n**, which is our chosen primary for both
> automation **and** AI/RAG orchestration (1,100+ integrations + community hub vs Flowise's ~100, and
> we have deep n8n experience). KB/RAG work follows [`docs/kb-standards.md`](../../../docs/kb-standards.md)
> on **n8n**. Flowise is kept running for now only for quick visual LLM-chain prototyping; **don't build
> production flows on it** — candidate for removal to cut attack surface. Decide keep-vs-remove later.

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
