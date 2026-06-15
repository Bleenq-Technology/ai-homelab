# SearXNG
**Purpose:** Privacy-respecting meta-search engine.
**URL:** https://searxng.pdx.sanctioned.tech
**Auth:** Keycloak forward-auth (Traefik middleware)
**Image:** searxng/searxng:latest
**GPU:** no
**Networks / data:** proxy, ai, data; bind mount `./searxng/config` -> `/etc/searxng`

## Setup as deployed
- Base URL: `SEARXNG_BASE_URL=https://searxng.${DOMAIN}/`.
- Secret: `SEARXNG_SECRET=${SEARXNG_SECRET}`.
- Redis (DB 6) for caching: `SEARXNG_REDIS_URL=redis://:${REDIS_PASSWORD}@redis:6379/6`.
- Config lives in `./searxng/config/settings.yml` (already present in the repo).
- Traefik router on `websecure`, TLS, middleware `secure-sso@file` (Keycloak forward-auth),
  backend port 8080.

## Issues & Fixes

**Symptom:** A hardcoded `redis.url` in `config/settings.yml` would override the authenticated `SEARXNG_REDIS_URL` environment value and drop the password (breaking Redis auth).
**Fix:** do not set the redis url in settings.yml — let the `SEARXNG_REDIS_URL` env var govern (it points at Redis DB 6 with the password).

## Secrets
- `SEARXNG_SECRET` — instance secret key.
- `REDIS_PASSWORD` — Redis auth (used inside `SEARXNG_REDIS_URL`).
- `DOMAIN`, `TZ`. All secrets come from `/opt/homelab/.env` (gitignored); nothing sensitive is committed.
