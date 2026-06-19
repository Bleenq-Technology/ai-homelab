# Adding an App to the Homelab — Developer Guide

End-to-end process for getting a new app running behind a custom
`*.pdx.sanctioned.tech` URL on the homelab, wired into auth, secrets, the database,
backups, and monitoring.

Works for **two kinds of app**:
- **Infra apps** — defined as a service in this repo's Compose layers (most apps).
- **External apps** — built/run elsewhere (own repo/image/host); you only need to
  publish a URL + plug into auth/secrets/monitoring. See the *External app* notes in
  each step.

> **For AI agents (Claude Code):** this doc is the source of truth for the workflow.
> Commands are copy-pasteable; `<app>` / `<APP>` / `<port>` are placeholders. The host
> is **Jarvis** (`ssh Jarvis`, user `sanctioned`, `192.168.2.10`, passwordless sudo).
> The deploy root `/opt/homelab` is a **plain copy of this repo's `docker/` tree** kept
> in sync by **scp** (no git on the host). Worked example throughout: **`librarian`**
> (the Discord→KB curator bot).

---

## 0. The flow at a glance

```
1. DNS      → point app.pdx.sanctioned.tech at Jarvis (firewall static-host-mapping)
2. Secrets  → push any creds to Infisical (push-secret.sh), add to .env.example
3. Database → (if needed) add Postgres DB/role; backups are then automatic
4. Compose  → add the service + Traefik labels (or a dynamic.yml route for external apps)
5. Auth     → pick: public | forward-auth SSO | native OIDC
6. Deploy   → scp changed files to /opt/homelab, recreate via the aggregate compose.yml
7. Monitor  → add an Uptime Kuma monitor (internal endpoint)
8. Verify   → curl the URL, check logs, confirm auth + health
```

Pre-flight checklist (tick before "done"):

- [ ] `app.pdx.sanctioned.tech` resolves to `192.168.2.10`
- [ ] Any secrets are in **Infisical** (not just `.env`) and in `.env.example` as placeholders
- [ ] DB/role created **and** added to the init script (if it uses Postgres)
- [ ] Service has Traefik labels: `Host()`, `websecure`, `tls=true`, a middleware chain, service port
- [ ] Auth decided and wired
- [ ] Files scp'd to `/opt/homelab`, service recreated, comes up healthy
- [ ] Uptime Kuma monitor added (internal endpoint, tagged by stack)
- [ ] `.env.example` / READMEs updated; changes committed

---

## 1. Topology you're plugging into

- **Edge:** Traefik v3 terminates TLS on the `websecure` entrypoint with **one wildcard
  cert** for `*.pdx.sanctioned.tech` (EasyDNS DNS-01). A routed service never needs its
  own cert — just a `Host()` rule.
- **Networks** (all external, created once): `proxy` (the edge — anything with a web
  route joins here), `data`, `ai`, `monitoring`. Join only what you need; web apps need
  `proxy`, DB-backed apps also need `data`.
- **Compose** is layered and unified by `/opt/homelab/compose.yml` (`include:` of
  `core/`, `data/`, `monitoring/`, `ai/`), project name **`homelab`**.
- **Secrets:** Infisical is the source of truth; `/opt/homelab/.env` is **generated**
  from it by `pull-secrets.sh`. See [core/infisical/README.md](../docker/core/infisical/README.md).
- **Identity:** Keycloak (`realm homelab`) + oauth2-proxy for forward-auth SSO. See
  [core/keycloak/README.md](../docker/core/keycloak/README.md).

---

## 2. DNS — point the hostname at Jarvis (firewall CLI)

Every `*.pdx.sanctioned.tech` name must resolve to Jarvis (`192.168.2.10`) on the LAN.
Add a static host mapping on the gateway/firewall (VyOS / EdgeRouter / EdgeOS syntax):

```bash
configure
set system static-host-mapping host-name librarian.pdx.sanctioned.tech inet 192.168.2.10
commit
save
exit
```

- Replace `librarian.pdx.sanctioned.tech` with your app's hostname.
- `inet 192.168.2.10` = Jarvis (where Traefik listens). Don't point it elsewhere.
- The wildcard TLS cert already covers any new `*.pdx.sanctioned.tech` host — no cert work.

Verify: `nslookup librarian.pdx.sanctioned.tech` (or `ping`) resolves to `192.168.2.10`.

> **External app on another host?** Still map the hostname to **Jarvis** and route
> through Traefik (Step 4, external variant) so it gets TLS + the shared auth/monitoring
> story — rather than exposing the other host directly.

---

## 3. Secrets — Infisical first, never hand-edit `.env`

`pull-secrets.sh` does `infisical export > .env`, which **truncates `.env` first** — so
anything only in `.env` is lost on the next pull/deploy. Always go through Infisical.
Full reference: [core/infisical/README.md](../docker/core/infisical/README.md).

**Add / update a secret — automated (CLI, preferred):**
```bash
ssh Jarvis
cd /opt/homelab
./push-secret.sh LIBRARIAN_API_KEY 's3cr3t-value'   # KEY VALUE -> Infisical (prod)
#   or: ./push-secret.sh LIBRARIAN_API_KEY           # reads the value from current ./.env
./pull-secrets.sh                                    # regenerate .env from Infisical
docker compose -f compose.yml up -d <service>        # recreate so it picks up the value
```
`push-secret.sh` writes to Infisical only and never prints the value (reports length +
reads back to verify).

**Add / update a secret — manually (web UI):**
1. https://infisical.pdx.sanctioned.tech → project **`homelab`** → environment **`prod`**.
2. *Add Secret* (or edit), set `KEY` = value. Add a short **note/description** (what it's
   for, which service).
3. On Jarvis: `./pull-secrets.sh` then recreate the service.

**Remove a secret:**
- UI: delete it from `homelab/prod`, then `./pull-secrets.sh` + recreate.
- CLI: `infisical secrets delete KEY --type=shared --projectId=… --env=prod --domain=… --token=…`
  (note `--type=shared` — without it the CLI assumes a personal secret and 400s).

**Always also** add the key to [`docker/.env.example`](../docker/.env.example) with a
**placeholder** (never the real value) so the variable is discoverable in git.

---

## 4. Database & backend integration (if the app needs Postgres)

One database + least-privilege role per service (pattern in
[`data/postgres/init/01-init-databases.sh`](../docker/data/postgres/init/01-init-databases.sh)).

1. **Secret:** `./push-secret.sh LIBRARIAN_DB_PASSWORD '…'` (+ `.env.example` placeholder).
2. **Init script (for clean rebuilds):** add a line —
   ```bash
   create_db_and_role librarian librarian "${LIBRARIAN_DB_PASSWORD}"
   ```
   ⚠️ The init script **only runs on an empty data dir**, so on the **already-running**
   Postgres you must create it live (mirror the function):
   ```bash
   ssh Jarvis
   docker exec -e PGPASSWORD="$(grep '^POSTGRES_PASSWORD=' /opt/homelab/.env|cut -d= -f2-|tr -d "\"'")" \
     postgres psql -U "$(grep '^POSTGRES_USER=' /opt/homelab/.env|cut -d= -f2-|tr -d "\"'")" -d postgres -v ON_ERROR_STOP=1 <<'SQL'
   DO $$ BEGIN IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname='librarian')
     THEN CREATE ROLE librarian LOGIN PASSWORD :'pw'; END IF; END $$;
   SQL
   # simplest: CREATE ROLE/DATABASE manually with the password you just pushed.
   ```
3. **Connect** from the app (it must join the `data` network):
   `postgresql://librarian:<pw>@postgres:5432/librarian`.
4. **Backups are automatic.** [`backup.sh`](../docker/backup.sh) runs nightly (`0 2 * * *`)
   and does `pg_dumpall`, so a new Postgres DB is captured with **no extra step**. Only if
   you add a *non-Postgres* datastore (a new object store, a different DB engine) do you
   extend `backup.sh`.

Other backends follow the same shape (Redis DB index, MinIO bucket via `minio-init`,
ClickHouse, etc.) — check the relevant `data/` service README.

---

## 5. Compose — define the service + route it

### 5a. Infra app (a service in this repo)

Add the service to the right layer (`core/` / `data/` / `monitoring/` / `ai/`). Minimal
routed-service shape — copy and adjust:

```yaml
  librarian:
    image: <your/image:tag>            # pin a tag; build: ./librarian if built here
    container_name: librarian
    restart: unless-stopped
    networks: [proxy, data]            # proxy = web route; data = Postgres; add others as needed
    environment:
      LIBRARIAN_DB_PASSWORD: ${LIBRARIAN_DB_PASSWORD}
      # ... other ${VARS} sourced from .env (which came from Infisical)
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.librarian.rule=Host(`librarian.${DOMAIN}`)"
      - "traefik.http.routers.librarian.entrypoints=websecure"
      - "traefik.http.routers.librarian.tls=true"
      - "traefik.http.routers.librarian.middlewares=secure-chain@file"   # see Step 6
      - "traefik.http.services.librarian.loadbalancer.server.port=<container-port>"
```

Middleware chains available (defined in
[`core/traefik/config/dynamic.yml`](../docker/core/traefik/config/dynamic.yml)):

| Middleware | Use for |
|---|---|
| `secure-chain@file` | hardening only — app does its own auth, or is intentionally public |
| `secure-sso@file` | hardening **+ Keycloak forward-auth SSO** (Step 6) |
| `secure-chain-stream@file` | streaming / websockets (no rate-limit) — chat, comfyui, uptime |
| `sso@file` | just the SSO gate, to combine with a stream chain: `sso@file,secure-chain-stream@file` |
| `secure-chain-frameable@file` | allows same-origin framing (Keycloak only) |

### 5b. External app (runs elsewhere, not a Compose service here)

Add a **file-provider** router + service in
[`core/traefik/config/dynamic.yml`](../docker/core/traefik/config/dynamic.yml) (hot-reloaded,
no restart) pointing at the external endpoint:

```yaml
http:
  routers:
    librarian:
      rule: "Host(`librarian.pdx.sanctioned.tech`)"
      entryPoints: ["websecure"]
      service: librarian
      middlewares: ["secure-chain"]      # or secure-sso for SSO
      tls: {}
  services:
    librarian:
      loadBalancer:
        servers:
          - url: "http://<host-or-container>:<port>"
```

Everything else (DNS, auth, secrets, monitoring) is identical.

---

## 6. Authentication — pick one

**Option A — Public / app-native login** (`secure-chain@file`). The app handles its own
auth (or is open on the trusted LAN). Nothing else to do. *(This is what `librarian`
currently uses — it returns `200` directly.)*

**Option B — Keycloak SSO via Traefik forward-auth** (easiest SSO; no app changes).
Set the router middleware to `secure-sso@file` (or `sso@file,secure-chain-stream@file`
for streaming apps). That's **it** — oauth2-proxy gates the route against Keycloak using
its **shared** client and the single callback `https://auth.${DOMAIN}/oauth2/callback`,
so **no per-host redirect URI and no new Keycloak client** are needed. Best for apps with
no/weak built-in auth (Prometheus, SearXNG, the Traefik dashboard, Uptime Kuma, …).
- Caveat: forward-auth only protects the **public route** — anything reaching the
  container directly on the internal networks is ungated. Fine for the trusted LAN.

**Option C — Native OIDC** (the app logs in to Keycloak itself; best when the app maps
users/roles — Grafana, Open WebUI, Portainer, Langfuse, MinIO console). Steps:
1. Create a confidential Keycloak client in realm `homelab` (admin UI, or `kcadm`):
   - `clientId` = your app, standard flow on, **redirect URI** = the app's callback,
     e.g. `https://librarian.${DOMAIN}/oauth_callback` (check the app's docs for the path).
2. Get the client secret and store it: `./push-secret.sh LIBRARIAN_OIDC_CLIENT_SECRET '…'`.
3. Configure the app's OIDC env (issuer
   `https://keycloak.${DOMAIN}/realms/homelab`, client id, `${LIBRARIAN_OIDC_CLIENT_SECRET}`,
   scopes `openid email profile`).
4. Bake the client into [`realm-homelab.json`](../docker/core/keycloak/realm-homelab.json)
   with `"secret": "REPLACE_AFTER_IMPORT"` (never the real value) for rebuild parity.
5. Route stays on `secure-chain@file` (the app does the OIDC dance, not the proxy).

Keycloak is the **source of truth** for client secrets; reconcile drift with
`core/keycloak/sync-oidc-secrets.sh`. See the keycloak README "Secrets & admin pipeline".

---

## 7. Deploy — scp to `/opt/homelab`, then recreate

The host has **no git** — you scp changed files into the matching path under
`/opt/homelab`, then recreate via the **aggregate** compose.

```bash
# from your repo's docker/ dir, for each changed file:
scp ai/compose.ai.yml                 Jarvis:/opt/homelab/ai/compose.ai.yml
scp data/postgres/init/01-init-databases.sh Jarvis:/opt/homelab/data/postgres/init/01-init-databases.sh
scp core/traefik/config/dynamic.yml   Jarvis:/opt/homelab/core/traefik/config/dynamic.yml   # if external route

# recreate the service (project = homelab):
ssh Jarvis 'cd /opt/homelab && docker compose -f compose.yml up -d librarian'
```

Gotchas:
- **Always drive `compose.yml`** (the aggregate, project `homelab`). Do **not** run
  `docker compose -f core/compose.core.yml up -d <svc>` directly — services set a hard
  `container_name`, so a non-aggregate invocation collides ("container name already in use").
- Some dirs under `/opt/homelab` are **root-owned** (e.g. `core/keycloak/`). scp to `/tmp`
  then `sudo install -o sanctioned -g sanctioned -m 644 /tmp/x /opt/homelab/core/keycloak/x`.
- Traefik `dynamic.yml` is **hot-reloaded** (file provider) — no Traefik restart needed.
- Compose changes need a service recreate to take effect; `.env` changes too (a running
  container keeps its env until recreated).

---

## 8. Monitoring — add to Uptime Kuma

Uptime Kuma is on **all four networks** so it can reach services on their **internal
container endpoint**, which **bypasses Traefik forward-auth** and gives a true backend
health signal (clean `200`) instead of the `302`-to-Keycloak you'd get on the public URL.

Add a monitor in the UI (https://uptime.pdx.sanctioned.tech):
- **HTTP(s)** monitor → URL = internal endpoint, e.g. `http://librarian:<port>/health`
  (use an **unauthenticated** health path; verify it returns `200` from inside the
  network). For SSO-gated public URLs, monitor the internal endpoint, not the public one.
- **TCP/port** monitor for non-HTTP services (e.g. a DB on `5432`).
- Edge cases: if a service's root only returns `302`/`401` unauthenticated, set the
  monitor to accept that code (as done for AdGuard).
- **Tag** it by stack (`core`/`data`/`monitoring`/`ai`) for filtering.

> Uptime Kuma **2.x dropped JSON import**, so `monitors-import.json` can't be uploaded —
> add new monitors **through the UI**. See
> [monitoring/uptime-kuma/README.md](../docker/monitoring/uptime-kuma/README.md).

Optional: add the app to the personal launchpad page (`homelab-apps.html`, kept outside
the repo).

---

## 9. Verify

```bash
ssh Jarvis '
  docker ps --filter name=librarian --format "{{.Names}}: {{.Status}}"   # running/healthy
  docker logs librarian --tail 30                                        # no startup errors
'
curl -sS -o /dev/null -w "%{http_code} -> %{redirect_url}\n" https://librarian.pdx.sanctioned.tech/
# Public/native-OIDC: 200.  Forward-auth SSO (unauthenticated): 302 -> keycloak login.
```

Then: log in (if gated), confirm the app works, confirm the Uptime Kuma monitor is green.

---

## 10. Commit

Commit the repo changes (compose layer, init script, `.env.example`, `dynamic.yml`,
`realm-homelab.json`, any README). **Never commit real secret values** — Infisical holds
those, and `realm-homelab.json` client secrets stay `REPLACE_AFTER_IMPORT`.

```bash
git add docker/ai/compose.ai.yml docker/.env.example docker/data/postgres/init/01-init-databases.sh
git commit -m "librarian: deploy Discord→KB curator behind librarian.pdx (app-auth)"
git push
```

---

## Quick reference

| Task | Where / command |
|---|---|
| DNS host → Jarvis | firewall: `set system static-host-mapping host-name <h> inet 192.168.2.10` |
| Add/rotate secret | `./push-secret.sh KEY VALUE` → `./pull-secrets.sh` → recreate |
| Remove secret | Infisical UI, or `infisical secrets delete KEY --type=shared …` |
| Regenerate `.env` | `./pull-secrets.sh` (from Infisical; truncates first) |
| New Postgres DB | `create_db_and_role` line in init script + create live on running PG |
| Backups | automatic via `backup.sh` (nightly) for Postgres/CH/QuestDB/MinIO |
| Deploy a change | `scp` file → `/opt/homelab/<path>`, then `docker compose -f compose.yml up -d <svc>` |
| Routing | Traefik labels (infra app) or `core/traefik/config/dynamic.yml` (external app) |
| Auth | middleware `secure-chain@file` (public) / `secure-sso@file` (SSO) / native OIDC client |
| Monitor | Uptime Kuma UI, internal endpoint, tag by stack |

Deep-dive docs: [core/infisical/README.md](../docker/core/infisical/README.md) ·
[core/keycloak/README.md](../docker/core/keycloak/README.md) ·
[core/traefik/README.md](../docker/core/traefik/README.md) ·
[monitoring/uptime-kuma/README.md](../docker/monitoring/uptime-kuma/README.md) ·
[docker/README.md](../docker/README.md)
