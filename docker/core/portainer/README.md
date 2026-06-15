# Portainer
**Purpose:** Docker management UI for the jarvis host.
**URL:** https://portainer.pdx.sanctioned.tech
**Auth:** Keycloak OAuth (configured in Portainer's UI; CE has no env config) + local admin
**Image:** portainer/portainer-ce:2.21.5
**Networks / data:** `proxy` (external); binds `/var/run/docker.sock` (ro) and `./portainer/data` -> `/data`

## Setup as deployed
- Routed via Traefik: `Host(portainer.${DOMAIN})`, `websecure`, `tls=true`, `secure-chain@file`; service port `9000`.
- First run: set the local admin password immediately (see gotcha below).
- SSO: configure OAuth in **Settings -> Authentication** using the Keycloak client `portainer`. Portainer CE cannot configure OAuth via environment variables, so this is done in the UI after first login.
- The local admin account remains as a fallback.

## Issues & Fixes

**Symptom:** The UI showed "Your Portainer instance timed out for security purposes. To re-enable your Portainer instance, you will need to restart Portainer."
**Fix:** Restart the container, then create/set the admin password within a few minutes of startup (Portainer disables itself if the admin isn't set shortly after first start).

## Secrets
- No secrets in compose env. The Keycloak client secret for the `portainer` OAuth client is entered directly in the Portainer UI, not via `.env`.
- `.env` key used indirectly: `DOMAIN` (for the route).
- Nothing sensitive is committed to git.
