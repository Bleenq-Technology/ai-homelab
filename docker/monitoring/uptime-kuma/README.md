# Uptime Kuma
**Purpose:** Self-hosted uptime / status board — health-checks every homelab service.
**URL:** https://uptime.pdx.sanctioned.tech
**Auth:** Keycloak SSO via Traefik **forward-auth** (`sso@file,secure-chain-stream@file`); Uptime
Kuma's own login is disabled (`disableAuth`) so there's no double prompt.
**Image:** louislam/uptime-kuma:2.4.0
**Networks / data:** `proxy`, `ai`, `data`, `monitoring`; named volume `uptime_kuma_data:/app/data`

## Setup as deployed
- Exposed on container port 3001; Traefik routes `uptime.${DOMAIN}` over `websecure` with TLS.
- **SSO via Keycloak forward-auth.** The route uses `sso@file,secure-chain-stream@file` — the
  `sso` forward-auth gate plus the streaming-friendly chain (no rate-limit, so socket.io isn't
  throttled), mirroring how ComfyUI is gated. Uptime Kuma has **no native OIDC/SAML** (free,
  open-source, but the feature doesn't exist in any version), so SSO is done at the proxy:
  - Built-in login is turned off via the **`disableAuth`** setting, so Keycloak is the only gate
    (no double prompt). `disableAuth` lives in the `uptime_kuma_data` volume (runtime setting, not
    in compose) — re-enable + re-disable from **Settings → Security** if rebuilding from scratch.
  - SSO uses the shared `sso@file` chain (oauth2-proxy) — no per-host redirect URI; the single
    `auth.${DOMAIN}/oauth2/callback` on the `oauth2-proxy` client covers every gated app.
  - **Trade-off:** forward-auth only protects the **public route**; with `disableAuth` on, anything
    that can reach the container directly on the internal Docker networks gets an unauthenticated
    dashboard. Standard homelab pattern (internal network trusted), but not the same as native SSO.
- **On all four networks on purpose.** That lets Uptime Kuma reach each service **directly on its
  internal container endpoint** (e.g. `http://grafana:3000/api/health`), which **bypasses Traefik's
  forward-auth**. The result is a true backend-health signal — clean `200`s — instead of the `302`
  redirect to Keycloak you'd get hitting the public URL of an SSO-gated service.
- **29 monitors**, seeded from [`monitors-import.json`](monitors-import.json). Each uses an
  unauthenticated health endpoint verified by probing from inside the container. Notable cases:
  - **TCP ("port") monitors** for non-HTTP services: Postgres `5432`, Redis `6379`,
    Wyoming Piper `10200`, Wyoming Whisper `10300`.
  - **NetBox** is monitored via its **public URL** (`https://netbox.…/login/`) — Django's
    `ALLOWED_HOSTS` rejects the internal container name with a `400`, so the public host (correct
    `Host:` header via Traefik) is used. It's local-login, not forward-auth, so it returns `200`.
  - **AdGuard** has no unauthenticated `200`; its root returns `302`, so that monitor accepts `302`.
- **Tags group monitors by stack** — `core` / `data` / `monitoring` / `ai` (colored) — for filtering.
- All state (monitors, settings, admin account) persists to the `uptime_kuma_data` volume.

### Seeding / re-provisioning (important: 2.x dropped JSON import)
`monitors-import.json` is a **1.23.x backup-import** file. **Uptime Kuma 2.x removed the
Backup/Import feature** (no `uploadBackup` handler, no import page), so it can't be uploaded on
2.4.0 directly. The monitors here were created by:
1. Importing the file on **1.23.16** via its socket API (below), then
2. Upgrading the container to **2.4.0** — the 1.x→2.x SQLite migration carried all 29 monitors
   forward (verified: `Aggregate Table Migration Completed`, 29/29 active & up).

To re-seed an empty instance, either temporarily run `1.23.16` and import, then upgrade — or script
creation against the live API. The import used here runs **inside** the 1.23.x container (which
bundles `socket.io-client`); note the importer writes explicit `NULL` for any omitted field, so the
JSON sets `invertKeyword` / `ignoreTls` / `maxredirects` on every monitor:
```js
// node /tmp/import.js  — login then uploadBackup
const { io } = require("/app/node_modules/socket.io-client");
const backup = require("fs").readFileSync("/tmp/monitors-import.json", "utf8");
const s = io("http://localhost:3001", { transports: ["websocket"], reconnection: false });
s.on("connect", () => s.emit("login", { username: "admin", password: "<pw>", token: "" }, () =>
  s.emit("uploadBackup", backup, "skip", res => { console.log(res); process.exit(res.ok ? 0 : 1); })));
```

### Backups
Uptime Kuma data is **SQLite in the `uptime_kuma_data` volume** — it is **not** in the
`pg_dumpall` backup. A pre-upgrade snapshot was saved to
`/opt/homelab/backups/uptime-kuma-pre-2.4.0.tar.gz`. Back up the volume directly when needed:
```bash
docker run --rm -v homelab_uptime_kuma_data:/data -v /opt/homelab/backups:/backup \
  alpine tar czf /backup/uptime-kuma-$(date +%F).tar.gz -C /data .
```

## Issues & Fixes

**Symptom:** socket import failed with `SQLITE_CONSTRAINT: NOT NULL constraint failed: monitor.invert_keyword` (and similarly for `ignore_tls` / `maxredirects` on TCP monitors).
**Fix:** the 1.x importer writes an **explicit `NULL`** for any field absent from the JSON, overriding the column default and violating `NOT NULL`. Set `invertKeyword`, `ignoreTls`, and `maxredirects` on **every** monitor in the file (done).

**Symptom:** NetBox monitor returned `400` on the internal endpoint `http://netbox:8000/login/`.
**Fix:** Django `ALLOWED_HOSTS` rejects the internal container hostname. Monitor NetBox via its public URL so Traefik passes the allowed `Host:` header.

**Symptom:** SSO-gated services showed only a `302` (to Keycloak) when checked via their public URL — that proves Traefik + Keycloak are up, not the backend.
**Fix:** add Uptime Kuma to the `ai` and `data` networks and target each service's **internal** container endpoint, which bypasses forward-auth and returns the app's real health.

**Symptom:** after upgrading to 2.x there was no way to import the monitor JSON.
**Fix:** the Backup/Import feature was removed in 2.0. Seed on 1.23.16 first, then upgrade — the DB migration carries the monitors forward.

**Symptom (original):** the admin account isn't provisioned by env/compose.
**Fix:** it's created on **first login** (initial setup screen) and stored in the `uptime_kuma_data` volume.

## Secrets
- Admin login only (local account) — kept in `LOCAL_LINKS.html` (gitignored). No env/Infisical secrets.
