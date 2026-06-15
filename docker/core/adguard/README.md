# AdGuard Home
**Purpose:** Network-wide DNS resolver + ad blocking for the LAN.
**URL:** https://adguard.pdx.sanctioned.tech (UI); DNS on `192.168.2.10:53` (TCP/UDP)
**Auth:** local login (set in first-run wizard)
**Image:** adguard/adguardhome:v0.107.55
**Networks / data:** `proxy` (external); binds `./adguard/work` and `./adguard/conf`

## Setup as deployed
- DNS bound specifically to the LAN IP: `${ADGUARD_DNS_IP:-192.168.2.10}:53` for both TCP and UDP (see gotcha).
- Port `3000:3000` published for the initial setup wizard (can be removed after first run).
- First-run wizard at `http://192.168.2.10:3000`:
  - Set the **Admin Web Interface** to port **80** (so Traefik can route it).
  - Set **DNS** to port **53**.
  - Create the admin username/password.
- After the wizard, the UI serves on `:80`; Traefik route `Host(adguard.${DOMAIN})`, `websecure`, `tls=true`, `secure-chain@file`, service port `80`.

## Issues & Fixes

**Symptom:** Container failed to start: `failed to set up container networking: ... failed to bind host port 0.0.0.0:53/tcp: address already in use`
**Fix:** Bind AdGuard's DNS to the LAN IP only (`${ADGUARD_DNS_IP:-192.168.2.10}:53`); the host's systemd-resolved already holds 127.0.0.53:53, so 0.0.0.0:53 conflicts.

**Symptom:** https://adguard.pdx.sanctioned.tech returned 502 Bad Gateway.
**Fix:** Complete the first-run setup wizard at http://192.168.2.10:3000 and set the Admin Web Interface to port 80 — AdGuard only serves :80 (where Traefik routes) after setup is finished.

## Secrets
- `.env` keys: `ADGUARD_DNS_IP` (defaults to `192.168.2.10`), `TZ`, `DOMAIN`. Exporter creds `ADGUARD_USERNAME` / `ADGUARD_PASSWORD` are consumed by the monitoring stack.
- AdGuard's own admin password is stored in `./adguard/conf` on jarvis, not in git.
- Nothing sensitive is committed to git.
