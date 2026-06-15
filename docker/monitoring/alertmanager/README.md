# Alertmanager
**Purpose:** Routes and de-duplicates alerts from Prometheus and dispatches notifications.
**URL:** https://alertmanager.pdx.sanctioned.tech
**Auth:** Keycloak forward-auth (`secure-sso@file` middleware)
**Image:** prom/alertmanager:v0.28.0
**Networks / data:** `proxy`, `monitoring`; config bind mount `./alertmanager:/etc/alertmanager:ro`, state on named volume `alertmanager_data:/alertmanager`

## Setup as deployed
- Started with `--config.file=/etc/alertmanager/config.yml` and `--storage.path=/alertmanager`.
- Exposed on container port 9093; Traefik routes `alertmanager.${DOMAIN}` over `websecure` with TLS, gated by `secure-sso@file` (Keycloak forward-auth).
- `config.yml` defines an SMTP email receiver driven by placeholder env (e.g. `ALERTMANAGER_EMAIL` and related SMTP settings).

## Fixes & gotchas
- The SMTP email receiver is **not yet wired to a real mailbox** — the `ALERTMANAGER_EMAIL` (and related) values are placeholders. Notifications will not be delivered until real SMTP/recipient values are set in `/opt/homelab/.env`.

## Secrets
- Uses `ALERTMANAGER_EMAIL` (and any related SMTP credential keys) for the email receiver, plus `DOMAIN` for Traefik routing.
- Nothing sensitive is committed; real values live in `/opt/homelab/.env` (gitignored). `docker/.env.example` ships placeholders only.
