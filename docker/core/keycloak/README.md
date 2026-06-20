# Keycloak SSO

Keycloak is the homelab identity provider. Realm **`homelab`** holds the users and
the OIDC clients; `master` is kept for Keycloak admin only.

## How services authenticate

- **Native OIDC** (the app talks to Keycloak directly): Grafana, Open WebUI,
  Portainer, Langfuse, **MinIO console**. Each has its own confidential client +
  redirect URI. (MinIO: console login only — the S3 API still uses access keys;
  client provisioned by [`provision-minio-client.sh`](provision-minio-client.sh),
  role mapped to `consoleAdmin` via `MINIO_IDENTITY_OPENID_ROLE_POLICY`.)
- **Forward-auth** (for apps with no/weak SSO): **oauth2-proxy** (Keycloak client
  `oauth2-proxy`) runs at the central auth domain `auth.${DOMAIN}`. Traefik calls it via the
  `sso@file` / `secure-sso@file` middleware (forwardAuth → `/oauth2/auth`; on no session an
  `errors` middleware rewrites the 401 to a 302 to Keycloak). One shared cookie on `.${DOMAIN}`,
  backed by **Redis sessions**, gives SSO across all gated apps — Prometheus, Alertmanager,
  SearXNG, ComfyUI, MLflow, the QuestDB/Traefik consoles, etc. Add more by simply setting a
  router's middleware to `secure-sso@file` — **no per-host redirect URI needed**, since every
  app shares the single callback `https://auth.${DOMAIN}/oauth2/callback`.
- The **Traefik dashboard** stays on basic-auth as a deliberate break-glass.
- **n8n / Flowise** gate OIDC behind paid tiers; **NetBox** needs a remote-auth
  plugin — these keep local logins (or can be forward-auth gated later).
- **Social login** (Google / LinkedIn) via identity brokering — see
  [`social-login.md`](social-login.md).

Client secrets live in `/opt/homelab/.env` on the host (`*_OIDC_CLIENT_SECRET`,
`OAUTH2_PROXY_CLIENT_SECRET`), never in git.

## Integrating a new app — choosing & wiring auth

**Decide by what the app needs, not by a ranking.** Native OIDC and forward-auth are
both first-class; they answer different questions:

| Choose… | When | Cost | Middleware | Examples |
|---|---|---|---|---|
| **Native OIDC** | the app **supports OIDC** *and* needs to **know who the user is** — per-user identity, roles/groups, attribution, audit | a per-app Keycloak **client + redirect URI + secret** | `secure-chain@file` (app does the login, not the proxy) | Grafana, Open WebUI, Portainer, Langfuse, MinIO console |
| **Forward-auth (oauth2-proxy)** | the app has **no / weak auth**, or doesn't speak OIDC, or you **only need a login gate** in front | **near-zero** — no per-app client, no redirect URI (shares the one `oauth2-proxy` client + single callback) | `secure-sso@file` (or `sso@file,secure-chain-stream@file` for websockets/streaming) | Prometheus, Alertmanager, SearXNG, ComfyUI, MLflow, Homarr, Uptime Kuma |
| **Public** | the route is **meant to be seen without login** and leaks nothing sensitive | none | `secure-chain@file` | a public landing page |

> **Rule of thumb:** reach for **forward-auth by default** — it's the lowest-friction gate and
> gives SSO across every gated app for free. Step up to **native OIDC only when the app must map
> identity inside itself** (different users see different things, RBAC, per-user data). Forward-auth
> is *not* a lesser fallback; native OIDC just buys in-app identity at the cost of a per-app client.
>
> Caveat: forward-auth only protects the **public Traefik route** — anything reaching the
> container directly on the internal networks is ungated (fine on the trusted LAN). Native OIDC
> protects the app itself.

### Forward-auth (the easy path) — one line
Set the router's middleware to **`secure-sso@file`** (websocket/streaming apps:
`sso@file,secure-chain-stream@file`). That's it — oauth2-proxy gates the route against Keycloak's
shared client at `https://auth.${DOMAIN}/oauth2/callback`. **No new Keycloak client, no per-host
redirect URI.** (Worked example: [`../homarr/README.md`](../homarr/README.md) §5.)

### Native OIDC — the recipe
Use when the app needs in-app identity. Steps (kcadm or the admin UI):

1. **Create the confidential client with `kcadm`** (our standard tool — same idiom as
   [`provision-minio-client.sh`](provision-minio-client.sh), the **copy-paste template** for a new
   app: it's idempotent, reads the secret back, and prints the sanitized client for the realm seed).
   The **redirect URI path is app-specific — check the app's docs** (Grafana `/login/generic_oauth`,
   Homarr `/api/auth/callback/oidc`, many use `/oauth_callback`):
   ```bash
   ssh Jarvis && cd /opt/homelab
   KC(){ docker exec keycloak /opt/keycloak/bin/kcadm.sh "$@"; }
   g(){ grep "^$1=" .env | cut -d= -f2- | sed -E "s/^['\"]//;s/['\"]\$//"; }
   # authenticate kcadm as the permanent master admin (creds from .env)
   KC config credentials --server http://localhost:8080 --realm master \
     --user "$(g KEYCLOAK_ADMIN)" --password "$(g KEYCLOAK_ADMIN_PASSWORD)"
   # create the client — swap <app> and the callback path for your app
   KC create clients -r homelab \
     -s clientId=<app> -s enabled=true -s protocol=openid-connect \
     -s publicClient=false -s standardFlowEnabled=true -s directAccessGrantsEnabled=false \
     -s 'redirectUris=["https://<app>.pdx.sanctioned.tech/<callback-path>","https://<app>.pdx.sanctioned.tech/*"]' \
     -s 'webOrigins=["https://<app>.pdx.sanctioned.tech"]'
   CID=$(KC get clients -r homelab -q clientId=<app> --fields id --format csv --noquotes)
   KC get "clients/$CID/client-secret" -r homelab        # -> {"value":"<the secret>"}
   ```
   Easiest path: **copy `provision-minio-client.sh` → `provision-<app>-client.sh`**, swap the
   `clientId` / redirect URIs / `*_OIDC_CLIENT_SECRET` var, and run it — it does all of the above
   plus writes the secret to `.env` and prints the sanitized client rep for step 5.
2. **Store the secret in Infisical:** `./push-secret.sh <APP>_OIDC_CLIENT_SECRET '<secret>'` then
   `./pull-secrets.sh`. Add a **placeholder** to [`docker/.env.example`](../../.env.example). The
   real value lives only in Keycloak, Infisical, and the host `.env` — **never in git**.
3. **Configure the app's OIDC env** (in its compose service): issuer
   `https://keycloak.${DOMAIN}/realms/homelab`, client id `<app>`,
   `${<APP>_OIDC_CLIENT_SECRET}`, scopes `openid email profile`.
4. **Roles/groups (only if the app does RBAC):** add a realm/client role + a group or roles mapper,
   and map it to the app's role config (see the MinIO console example —
   [`provision-minio-client.sh`](provision-minio-client.sh) + `*_ROLE_POLICY`).
5. **Bake the client into [`realm-homelab.json`](realm-homelab.json)** with
   `"secret": "REPLACE_AFTER_IMPORT"` (never the real value) so a clean realm import reproduces it.
6. **Route stays on `secure-chain@file`** — the app performs the OIDC dance itself; do **not** also
   put `secure-sso` in front (that would double-gate).
7. Reconcile/rotate the secret with [`sync-oidc-secrets.sh`](sync-oidc-secrets.sh) (Keycloak is the
   source of truth; a running container's value is not authoritative).

Prereqs already satisfied for every app: TLS + `KC_HOSTNAME=https://…` + `KC_PROXY_HEADERS=xforwarded`
give OIDC the secure context/correct redirect URLs it needs.

> **Switching an app from forward-auth → native OIDC later** (e.g. Homarr, to map users): create
> the client (steps 1–5), remove `sso@file`/`secure-sso@file` from its router and set
> `secure-chain@file`, recreate. Nothing else in the stack changes.

## Reproducing the realm

[`realm-homelab.json`](realm-homelab.json) is a sanitized export (client secrets
replaced with `REPLACE_AFTER_IMPORT`). To recreate the realm on a fresh Keycloak:

```bash
# import the realm
docker exec keycloak /opt/keycloak/bin/kcadm.sh config credentials \
  --server http://localhost:8080 --realm master --user admin --password "$KEYCLOAK_ADMIN_PASSWORD"
docker cp docker/core/keycloak/realm-homelab.json keycloak:/tmp/realm.json
docker exec keycloak /opt/keycloak/bin/kcadm.sh create realms -f /tmp/realm.json

# then regenerate each client secret and write it back into .env, e.g.:
docker exec keycloak /opt/keycloak/bin/kcadm.sh get clients -r homelab -q clientId=grafana --fields id
docker exec keycloak /opt/keycloak/bin/kcadm.sh create clients/<id>/client-secret -r homelab
```

Recreate the user (`paul`) and set a password with `create users` / `set-password`.

After importing, run the post-import helpers to apply the bits that don't live in
the realm export:

```bash
./core/keycloak/configure-smtp.sh           # Mailjet SMTP + reset/verify
./core/keycloak/configure-passkeys.sh        # WebAuthn passwordless policy + Enable Passkeys
./core/keycloak/add-passkey-2fa-skip.sh      # browser-passkeys flow (skip OTP after passkey)
```

## Secrets & admin pipeline

**Keycloak is the source of truth for confidential-client secrets.** They flow:

```
Keycloak (kcadm)  ->  Infisical (prod)  ->  .env  ->  containers
                                   pull-secrets.sh   compose
```

- `realm-homelab.json` ships every client secret as `REPLACE_AFTER_IMPORT` (never
  real values — those are only ever in Keycloak's DB, Infisical, and the host `.env`).
- `pull-secrets.sh` does `infisical export > .env`, which **truncates `.env` first**.
  If a value isn't in Infisical it won't survive a re-pull — so add new secrets to
  Infisical, not just `.env`. (A deleted/empty `.env` cascades: recreated containers
  get blank config — grafana crashes on an empty SMTP address, oauth2-proxy fails token
  exchange with `invalid_client`. Fix: `./pull-secrets.sh`, then recreate.)

Helpers (all idempotent, run from `/opt/homelab`):

```bash
./core/keycloak/provision-permanent-admin.sh   # create permanent master admin -> Infisical
./core/keycloak/sync-oidc-secrets.sh           # reconcile KC client secrets -> Infisical -> .env
./core/keycloak/provision-minio-client.sh      # create the minio OIDC client (console SSO)
```

- **Permanent admin** (`keycloak-admin`): Keycloak 26's `KC_BOOTSTRAP_ADMIN_*` account
  is **temporary and expires mid-run**, which silently breaks `kcadm` (`invalid_grant`).
  `provision-permanent-admin.sh` creates a real master-realm admin with the `admin`
  role and stores it as `KEYCLOAK_ADMIN` / `KEYCLOAK_ADMIN_PASSWORD` in Infisical, so
  automation no longer depends on the bootstrap account. Run it once while a valid
  admin session exists (e.g. just after a Keycloak recreate).
- **Reconcile drift**: if a client secret in `.env`/Infisical ever diverges from
  Keycloak (a running container's value is *not* authoritative — verify against
  Keycloak), `sync-oidc-secrets.sh` pushes Keycloak's values back into Infisical and
  re-pulls `.env`. To **rotate** a secret: `kcadm create clients/<id>/client-secret`,
  then `sync-oidc-secrets.sh` to propagate.

## Email / SMTP (password reset, verification)

The realm sends mail via **Mailjet** using the shared `SMTP_*` creds (Infisical →
`.env`), with **password reset** and **email verification** enabled. Apply (or
re-apply after a realm rebuild) with the idempotent helper:

```bash
./core/keycloak/configure-smtp.sh      # run from /opt/homelab
```

It reads `SMTP_*` + the admin creds from `.env` and sets `realms/homelab`
`smtpServer` + `resetPasswordAllowed` + `verifyEmail` via `kcadm`.

**Notes & gotchas:**
- kcadm can't set the `smtpServer` map with `-s key.subkey=...` and `--fields
  smtpServer` won't echo a nested map back — the script applies a JSON file with
  `-f` (read the *full* realm to verify, not `--fields`).
- The `SMTP_FROM` address must be a **Mailjet-verified sender** or mail is rejected.
- Mailjet SMTP: port **587**, **StartTLS** (`ssl=false`, `starttls=true`),
  `user` = API key, `password` = secret key.
- The same `SMTP_*` creds are reused by Grafana, NetBox, and Baserow.

## Passkeys (passwordless WebAuthn)

Keycloak 26 supports **passkeys** — discoverable WebAuthn credentials that log a
user in with a biometric/PIN and no password. This covers **iPhone Face ID**
(and Touch ID, Windows Hello, Android, hardware keys like YubiKey): the passkey is
created in iCloud Keychain and used either directly in Safari on the phone, or
**cross-device** from a desktop browser by scanning a QR code and approving with
Face ID (the WebAuthn "hybrid" transport).

Passkeys are **GA / enabled by default** as of Keycloak 26.4 (this image is
26.6.3), so **no `KC_FEATURES` flag is needed** — the `PASSKEYS` feature reports
`enabled=true, type=DEFAULT` out of the box. (It was a preview feature `passkeys`
in 26.0–26.3; if you ever pin one of those, add `KC_FEATURES: passkeys` to the
service.) The only thing to configure is the realm policy:

- **Realm policy** — apply (or re-apply after a realm rebuild) with the idempotent
  helper:

   ```bash
   ./core/keycloak/configure-passkeys.sh     # run from /opt/homelab
   ```

   It sets the **WebAuthn Passwordless Policy** (RP ID = the parent `${DOMAIN}` so one
   passkey works across every `*.${DOMAIN}` app; require resident key = Yes; user
   verification = required), enables the `webauthn-register-passwordless` required
   action, and flips the **Enable Passkeys** switch
   (`webAuthnPolicyPasswordlessPasskeysEnabled`). With Passkeys on, the **default
   browser flow** shows the conditional/modal passkey prompt automatically — no flow
   editing needed (26.4+).

Users self-enroll at `https://keycloak.${DOMAIN}/realms/homelab/account/` →
**Account security → Signing in → Passkey**. To force enrollment, add the
`webauthn-register-passwordless` required action to the user.

### Skip 2FA when a passkey is used

A passkey already proves possession + user verification, so a second OTP factor is
redundant after a passkey login. Keycloak's built-in `browser` flow can't be edited
in place, so the idempotent helper

```bash
./core/keycloak/add-passkey-2fa-skip.sh     # run from /opt/homelab
```

duplicates `browser` → **`browser-passkeys`**, adds a **Condition - credential**
(`credentials=[webauthn-passwordless]`, `included=false`) ahead of the OTP Form in
the "Browser - Conditional OTP" subflow, and binds `browser-passkeys` as the realm
browser flow. Net effect: OTP runs for password logins but is **skipped after a
passkey login** — the same behaviour as the Keycloak 26.4 default browser flow.

This is a **post-import helper** (like the SMTP/passkey-policy ones), not baked into
`realm-homelab.json`: on a fresh import the `browser-passkeys` copy doesn't exist
yet, so the realm export keeps `browserFlow: browser` and the helper creates + binds
the copy afterward.

**Notes & gotchas:**
- WebAuthn needs a secure context — satisfied by Traefik TLS + `KC_HOSTNAME=https://…`
  and `KC_PROXY_HEADERS=xforwarded`.
- The passwordless-policy fields + `webAuthnPolicyPasswordlessPasskeysEnabled: true`
  are baked into [`realm-homelab.json`](realm-homelab.json), so a clean realm import
  comes up passkey-ready; `configure-passkeys.sh` is the idempotent re-apply for an
  already-running realm. (We patch those fields in place rather than a full `kc.sh
  export`, which would splice real client secrets over the `REPLACE_AFTER_IMPORT`
  placeholders.)
- RP ID `${DOMAIN}` means passkeys are bound to that registrable domain; they won't
  work if a service is reached over a bare IP or a different domain.

## Custom login theme (`homelab`)

[`themes/homelab/`](themes/homelab) is a minimal **login** theme (parent
`keycloak.v2`) mounted at `/opt/keycloak/themes` and set as the realm `loginTheme`
(baked into `realm-homelab.json`). It exists for one reason: stock Keycloak pops a
`window.prompt()` asking the user to **name the passkey** right after creating it
(fired by `webauthnRegister.js`), which users found confusing.

It overrides a single template, [`login/webauthn-register.ftl`](themes/homelab/login/webauthn-register.ftl),
replacing the dialog's `window.prompt` with a function that returns a **unique**
auto-label (`Passkey <timestamp>`) just before registration runs. The stock JS uses
that returned string as the label and auto-submits, so the dialog never appears.
The label must be unique because **Keycloak rejects duplicate WebAuthn labels** — a
constant default would break enrolling a 2nd passkey. The JS itself is **not**
overridden, so this survives Keycloak upgrades; only re-check the FTL if upstream
rewrites `webauthn-register.ftl`.

**Notes:**
- Theme caching is on in `start` mode — **recreate the keycloak container** after
  changing theme files (`docker compose -f compose.yml up -d --force-recreate keycloak`).
- The theme provides only the `login` type; the account console stays on stock
  `keycloak.v3`.
