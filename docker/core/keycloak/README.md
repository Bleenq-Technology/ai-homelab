# Keycloak SSO

Keycloak is the homelab identity provider. Realm **`homelab`** holds the users and
the OIDC clients; `master` is kept for Keycloak admin only.

## How services authenticate

- **Native OIDC** (the app talks to Keycloak directly): Grafana, Open WebUI,
  Portainer, Langfuse. Each has its own confidential client + redirect URI.
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
