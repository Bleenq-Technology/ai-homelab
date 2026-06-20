# Deploying Homarr to the homelab

Homarr as the live launchpad (replacing `homelab-apps.html`), wired into
Traefik + Keycloak SSO + Uptime Kuma. Host: **`home.pdx.sanctioned.tech`**.
Follows the repo's [`adding-an-app.md`](../../../docs/adding-an-app.md) flow —
this is the Homarr-specific fill-in. It's an **infra app** (a service in
`core/compose.core.yml`), so no `dynamic.yml` route is needed.

Deployed straight to Jarvis (the homelab is local — a misbehaving Homarr is
just `docker compose stop homarr`, and the service is purely additive so it
can't affect anything else).

---

## 1. DNS — point the hostname at Jarvis

On the gateway/firewall:

```bash
configure
set system static-host-mapping host-name home.pdx.sanctioned.tech inet 192.168.2.10
commit
save
exit
```

Verify: `nslookup home.pdx.sanctioned.tech` → `192.168.2.10`. The wildcard TLS
cert already covers it.

## 2. Secret — push the encryption key to Infisical

Homarr needs `SECRET_ENCRYPTION_KEY` (64-char hex; it encrypts stored
integration creds). The compose maps it from `HOMARR_SECRET_ENCRYPTION_KEY`.

```bash
ssh Jarvis
cd /opt/homelab
./push-secret.sh HOMARR_SECRET_ENCRYPTION_KEY "$(openssl rand -hex 32)"
#   If you already set a key locally and want continuity, push THAT value
#   instead so your tested integrations carry over:
#   ./push-secret.sh HOMARR_SECRET_ENCRYPTION_KEY '<your-local-hex-key>'
./pull-secrets.sh
```

`.env.example` already carries `HOMARR_SECRET_ENCRYPTION_KEY` as a placeholder.

> Keep this key stable. Rotating it makes every saved Homarr integration secret
> undecryptable (you'd re-enter them).

## 3. Database — none (but backed up)

Homarr stores its config in SQLite under `/appdata` (the bind mount). No
Postgres role, no init-script line. Since `pg_dumpall` won't capture a SQLite
dir, `backup.sh` has a dedicated `backup_homarr()` step that tars
`core/homarr/appdata` into `backups/` — so it rides the nightly 2am cron, the
MinIO copy, `RETAIN_DAYS` pruning, and the restic off-host replica to the NAS
like every other datastore.

## 4. Compose — already in `core/compose.core.yml`

The service block is committed (between `portainer` and `infisical`):

```yaml
homarr:
    image: ghcr.io/homarr-labs/homarr:v1.67.0
    container_name: homarr
    restart: unless-stopped
    networks: [proxy, data]
    environment:
        SECRET_ENCRYPTION_KEY: ${HOMARR_SECRET_ENCRYPTION_KEY}
    volumes:
        - /var/run/docker.sock:/var/run/docker.sock:ro
        - ./homarr/appdata:/appdata
    labels:
        - "traefik.enable=true"
        - "traefik.http.routers.homarr.rule=Host(`home.${DOMAIN}`)"
        - "traefik.http.routers.homarr.entrypoints=websecure"
        - "traefik.http.routers.homarr.tls=true"
        - "traefik.http.routers.homarr.middlewares=sso@file,secure-chain-stream@file"
        - "traefik.http.services.homarr.loadbalancer.server.port=7575"
```

Notes on the choices:

- **`networks: [proxy, data]`** — `proxy` for the web route; `data` so Homarr
  can reach Uptime Kuma (and other backends) on their internal endpoints.
- **Docker socket (ro)** — powers the live container-status integration.
- **`sso@file,secure-chain-stream@file`** — SSO gate + the _stream_ chain
  (no rate-limit), because Homarr holds a websocket open for live tiles. This
  mirrors how `uptime` is routed.

## 5. Auth — Keycloak forward-auth SSO (Option B)

The `sso@file` middleware gates the public route via oauth2-proxy against
Keycloak's shared client — **no per-host redirect URI, no new Keycloak
client**. One homelab login covers it.

Homarr also has its own login; with forward-auth in front, the simplest model
is to treat Homarr as single-user (you reach it already authenticated by
Keycloak). If later you want Homarr to map Keycloak users/groups itself, switch
to native OIDC (Option C) — Homarr supports an OIDC provider — but that's
optional and not needed to go live.

### Native OIDC (optional upgrade) — Homarr ↔ Keycloak

Switch Homarr from the forward-auth gate to **its own** Keycloak login (so Homarr
knows the user and you get one "Keycloak" button instead of a double prompt). Decision
principle + general recipe: [`../keycloak/README.md`](../keycloak/README.md) →
*Integrating a new app*. The env below is **pinned to Homarr's official OIDC docs**
(homarr.dev → Single Sign-On); Homarr is **v1.67.0** here, at `https://home.pdx.sanctioned.tech`.

**1. Create the Keycloak client** — run the ready provisioning script (idempotent;
creates the `homarr` client with the correct redirect, adds a `groups` claim mapper for
role mapping, writes `HOMARR_OIDC_CLIENT_SECRET` to `.env`, and prints the sanitized
client for the realm seed):
```bash
ssh Jarvis && cd /opt/homelab
./core/keycloak/provision-homarr-client.sh          # prints the sanitized client rep (save it for step 5)
```
> Callback/redirect URI it registers: `https://home.pdx.sanctioned.tech/api/auth/callback/oidc`
> (Homarr's fixed OIDC callback path).

**2. Store the secret in Infisical** + add the `.env.example` placeholder:
```bash
./push-secret.sh HOMARR_OIDC_CLIENT_SECRET    # reads the value the script just wrote to ./.env
./pull-secrets.sh
```
Add `HOMARR_OIDC_CLIENT_SECRET=<placeholder>` to [`../../.env.example`](../../.env.example).

**3. Configure Homarr's OIDC env** in the `homarr` service (`core/compose.core.yml`) —
**verified against Homarr v1 docs**:
```yaml
      AUTH_PROVIDERS: "oidc,credentials"        # comma-sep; drop "credentials" to remove local login
      AUTH_OIDC_CLIENT_ID: "homarr"
      AUTH_OIDC_CLIENT_SECRET: ${HOMARR_OIDC_CLIENT_SECRET}
      AUTH_OIDC_ISSUER: "https://keycloak.${DOMAIN}/realms/homelab"
      AUTH_OIDC_CLIENT_NAME: "Keycloak"         # login-button label (default "OIDC")
      AUTH_OIDC_SCOPE_OVERWRITE: "openid email profile groups"   # default; keep "groups" for role mapping
      AUTH_OIDC_GROUPS_ATTRIBUTE: "groups"      # claim Homarr maps groups from (default; matches the mapper)
      # AUTH_OIDC_AUTO_LOGIN: "true"            # optional: skip Homarr's login page, go straight to Keycloak
```
Notes / gotchas (all confirmed):
- **Reverse proxy:** Homarr (Auth.js) derives its callback from the `X-Forwarded-Proto/Host`
  headers our `secure-chain*` middleware already sets, so it resolves to
  `https://home.${DOMAIN}/...` automatically — **no base-URL var needed**. (If you ever see a
  redirect to `http://localhost:7575`, that's a missing `X-Forwarded-Host`, not a Homarr setting.)
- **Auth secret:** Homarr v1 uses Auth.js. If startup/login errors about a missing secret, set
  `AUTH_SECRET` to a random value (store as `HOMARR_AUTH_SECRET` in Infisical) — separate from the
  existing `SECRET_ENCRYPTION_KEY`.
- **Admin via Keycloak groups:** the script adds a `groups` mapper, so a Keycloak group flows to
  Homarr under the `groups` claim. Create a Keycloak group and a **same-named** Homarr group with
  admin perms → members inherit it on login (`AUTH_OIDC_GROUPS_LOCAL_MANAGEMENT` left `false`, so
  Keycloak is authoritative for membership). Simplest start: skip groups and just promote the first
  OIDC user in Homarr → Manage → Users.

**4. Drop the forward-auth gate** (else you double-gate: oauth2-proxy *then* Homarr's own login).
Change the router middleware from `sso@file,secure-chain-stream@file` to just
**`secure-chain-stream@file`** (keep the stream chain for Homarr's websocket):
```yaml
      - "traefik.http.routers.homarr.middlewares=secure-chain-stream@file"
```

**5. Bake + deploy:** paste the sanitized client (`"secret":"REPLACE_AFTER_IMPORT"`) from step 1
into [`../keycloak/realm-homelab.json`](../keycloak/realm-homelab.json), scp the changed
`compose.core.yml` / `.env.example` (via `/tmp` + `sudo install`, per Step 6), recreate `homarr`,
and verify `https://home.pdx.sanctioned.tech/` now shows **Homarr's** login with a **Keycloak**
button (not the oauth2-proxy `302`). Log in, confirm you land in Homarr as that user.

## 6. Deploy — scp via /tmp + recreate via the aggregate compose

`/opt/homelab` files are owned by `sanctioned`, so scp can't write there
directly — land in `/tmp`, then `sudo install` into place with the right
owner. From your repo's `docker/` dir:

```bash
scp core/compose.core.yml Jarvis:/tmp/compose.core.yml
scp .env.example          Jarvis:/tmp/.env.example
ssh Jarvis
sudo install -o sanctioned -g sanctioned -m 644 /tmp/compose.core.yml /opt/homelab/core/compose.core.yml
sudo install -o sanctioned -g sanctioned -m 644 /tmp/.env.example      /opt/homelab/.env.example

# recreate just this service as the sanctioned user (project = homelab):
sudo -u sanctioned bash -c 'cd /opt/homelab && docker compose -f compose.yml up -d homarr'
```

(You already pushed the real key + pulled `.env` in Step 2.) The `appdata` dir
is created on first run.

> Image tag gotcha: the ghcr tags carry a **`v` prefix** (`v1.67.0`, not
> `1.67.0`) — a bare number 404s with "not found".

## 7. Monitor — add to Uptime Kuma

In https://uptime.pdx.sanctioned.tech, add an **HTTP(s)** monitor against the
internal endpoint (bypasses forward-auth → clean 200):

- URL: `http://homarr:7575/` (internal container name + port)
- Tag: `core`

## 8. Verify

```bash
ssh Jarvis '
  docker ps --filter name=homarr --format "{{.Names}}: {{.Status}}"
  docker logs homarr --tail 30
'
curl -sS -o /dev/null -w "%{http_code} -> %{redirect_url}\n" https://home.pdx.sanctioned.tech/
# Unauthenticated: 302 -> keycloak login (forward-auth gate). After login: the dashboard.
```

## 9. Commit

```bash
git add docker/core/compose.core.yml docker/.env.example docker/.gitignore \
        docker/backup.sh docker/core/homarr/
git commit -m "homarr: add dashboard launchpad + nightly backup"
git push
```

---

## Wiring the Uptime Kuma integration (the part you asked about)

**Do not point Homarr at Kuma's SQLite DB.** Homarr's Uptime Kuma integration
reads Kuma's **status-page API**, identified by a _slug_ — not `kuma.db`. This
is the supported, upgrade-safe path (no shared volume, no lock contention).

1. **In Uptime Kuma** — create a Status Page (left nav → _Status Pages_ → add),
   add the monitors you want surfaced, and save. Note its slug — the URL path,
   e.g. `/status/default` → slug `default`.
2. **In Homarr** — Settings → Integrations → add **Uptime Kuma**. URL =
   `http://uptime-kuma:3001` (internal name + port, reachable because Homarr is
   on the `data`/`monitoring` reachable path) and set the **Slug** secret to
   the status-page slug from step 1. If you leave the slug blank, Homarr
   assumes `default`.
3. Add the **Uptime Kuma widget** to a board — it shows monitor uptime stats,
   average uptime %, and up/down counts pulled from that status page.

> Internal reachability: Homarr is on `proxy` + `data`. Uptime Kuma is on all
> four nets including `data`, so `http://uptime-kuma:3001` resolves
> container-to-container without going through Traefik (and without tripping the
> SSO gate). If you ever move Homarr off a shared net with Kuma, add the
> `monitoring` net to Homarr's `networks:` list.

Separately, the **Docker integration** (socket already mounted) gives live
container state for the whole `homelab` project — pair the two for "is the
container up _now_" (Docker) plus "what's its uptime history" (Kuma).

### Integration URLs — use internal endpoints, not the public host

Integration connections are server-side calls from the Homarr container, so
point them at the **internal** `http://<container>:<port>`, not the public
`https://<app>.pdx...` URL (which routes back through Traefik/SSO and fails):

- Uptime Kuma → `http://uptime-kuma:3001` (status-page slug, see above)
- AdGuard Home → `http://adguard:80` — **pending**: needs AdGuard's admin
  user/password (not the Homarr login), which weren't on hand at setup.
- Docker → the mounted socket, no URL.

The clickable app *tile* URLs are the opposite — those stay the public
`https://<app>.pdx.sanctioned.tech` so they open in the browser.
