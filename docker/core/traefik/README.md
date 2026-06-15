# Traefik
**Purpose:** Edge reverse proxy + wildcard TLS termination for all `*.pdx.sanctioned.tech` services.
**URL:** https://traefik.pdx.sanctioned.tech/dashboard/
**Auth:** dashboard gated by Keycloak forward-auth (`secure-sso@file`)
**Image:** traefik:v3.7.5
**Networks / data:** `proxy` (external); binds `/var/run/docker.sock` (ro), `./traefik/config/traefik.yml`, `./traefik/config/dynamic.yml`, and `./traefik/letsencrypt` (ACME store)

## Setup as deployed
- Ports `80:80` and `443:443` published on the host.
- EasyDNS DNS-01 resolver `le` issues the single wildcard cert for `*.pdx.sanctioned.tech`. EasyDNS credentials are passed as Docker secrets (`easydns_token`, `easydns_key` from `../secrets/`) and read by lego via `EASYDNS_TOKEN_FILE` / `EASYDNS_KEY_FILE` env (`_FILE` pattern); `EASYDNS_ENDPOINT=https://rest.easydns.net`.
- `DOCKER_API_VERSION: "1.44"` pins a Docker API version the engine accepts.
- The wildcard cert lands in the default store on the `websecure` entrypoint, so every other service just sets `tls=true` + `secure-chain@file` and inherits it — no per-service certresolver label.
- Dashboard router (`dashboard`): `Host(traefik.${DOMAIN})`, `websecure`, `service=api@internal`, middleware `secure-sso@file` (Keycloak forward-auth) — log in via Keycloak to reach `/dashboard/`.
- Prometheus metrics are exposed on an internal `:8082` entrypoint.
- `dynamic.yml` defines the shared middlewares: `secure-chain`, `secure-chain-stream`, `sso`, `secure-sso`.
- Healthcheck: `traefik healthcheck --ping`.

## Issues & Fixes

**Symptom:** Traefik's Docker provider crash-looped, logging repeatedly: `Failed to retrieve information of the docker client and server host error="...client version 1.24 is too old. Minimum supported API version is 1.40, please upgrade your client to a newer version"`
**Fix:** Upgrade the Traefik image from v3.3 to v3.7.5 — v3.3's bundled Docker client pinned API 1.24, which Docker Engine 29 rejects.

**Symptom:** Every service served Traefik's self-signed DEFAULT certificate; `acme.json` stayed 0 bytes and no DNS-01 challenge was ever attempted.
**Fix:** Add the wildcard `tls.domains` (main `pdx.sanctioned.tech` + SAN `*.pdx.sanctioned.tech`) and `tls.certresolver=le` onto the dashboard ROUTER labels — defining `tls.domains` only at the entrypoint level did not trigger ACME issuance.

**Symptom:** after secrets moved to Infisical, the dashboard returned 404 (basicauth middleware invalid). Infisical exports `.env` values single-quoted, which made the `$$`-escaped apr1 hash literal, corrupting the htpasswd users.
**Fix:** gate the dashboard with Keycloak forward-auth (`secure-sso@file`) and drop the basicauth hash entirely — `TRAEFIK_DASHBOARD_AUTH` was the only `$`-containing value, so this also makes the quoted `.env` fully clean.

## Secrets
- `.env` keys: `DOMAIN` (dashboard is SSO-gated; no basicauth secret).
- EasyDNS credentials are NOT in `.env` — they are Docker secrets sourced from `../secrets/easydns_token` and `../secrets/easydns_key`.
- Nothing sensitive is committed to git; real values live in `/opt/homelab/.env` and the secrets files on jarvis.
