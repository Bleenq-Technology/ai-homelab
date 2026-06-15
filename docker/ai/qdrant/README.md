# Qdrant
**Purpose:** Vector database.
**URL:** https://qdrant.pdx.sanctioned.tech (REST/dashboard, port 6333)
**Auth:** API key
**Image:** qdrant/qdrant:v1.12.5
**GPU:** no
**Networks / data:** proxy, ai; bind mount `./qdrant/data` -> `/qdrant/storage`

## Setup as deployed
- API key auth: `QDRANT__SERVICE__API_KEY=${QDRANT_API_KEY}`. Clients and the dashboard must
  present this key (`api-key` header).
- Storage persists under `./qdrant/data` (`/qdrant/storage`).
- Traefik router on `websecure`, TLS, middleware `secure-chain@file`, backend port 6333
  (REST API + web dashboard at `/dashboard`).

## Fixes & gotchas
- No service-specific fixes. Access is gated by the API key rather than Keycloak.

## Secrets
- `QDRANT_API_KEY` — service API key.
- `TZ`. All secrets come from `/opt/homelab/.env` (gitignored); nothing sensitive is committed.
