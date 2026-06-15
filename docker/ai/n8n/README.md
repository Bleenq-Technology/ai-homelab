# n8n
**Purpose:** Workflow automation.
**URL:** https://n8n.pdx.sanctioned.tech
**Auth:** local login (n8n owner account)
**Image:** n8nio/n8n:1.74.1
**GPU:** no
**Networks / data:** proxy, ai, data; bind mount `./n8n/data` -> `/home/node/.n8n`

## Setup as deployed
- Reverse-proxy / URL config:
  - `N8N_HOST=n8n.${DOMAIN}`, `N8N_PROTOCOL=https`
  - `WEBHOOK_URL=https://n8n.${DOMAIN}/`, `N8N_EDITOR_BASE_URL=https://n8n.${DOMAIN}/`
  - `N8N_PROXY_HOPS=1` (single proxy hop behind Traefik)
- `N8N_ENCRYPTION_KEY=${N8N_ENCRYPTION_KEY}` for credential encryption.
- `GENERIC_TIMEZONE=${TZ}`, `TZ=${TZ}`.
- Traefik router on `websecure`, TLS, middleware `secure-chain-stream@file`, backend port 5678.

### First login
- On first visit you create the **local owner account**.

## Issues & Fixes

**Symptom:** Container crash-looped; logs showed `EACCES: permission denied, open '/home/node/.n8n/config'`.
**Fix:** chown the bind data directory to `1000:1000` (n8n runs as uid 1000).

## Secrets
- `N8N_ENCRYPTION_KEY` — encrypts stored credentials (do not lose/rotate carelessly).
- `DOMAIN`, `TZ`.
- All secrets come from `/opt/homelab/.env` (gitignored); nothing sensitive is committed.
