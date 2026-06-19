# Social login (Google / LinkedIn) for the `homelab` realm

How to add **identity brokering** — letting users sign in to homelab apps with their
Google or LinkedIn account. Keycloak is the broker: the app still talks only to
Keycloak (OIDC), and Keycloak federates out to Google/LinkedIn behind the login page.

- Realm: **`homelab`**  ·  Keycloak: `https://keycloak.${DOMAIN}` (`${DOMAIN}` = `pdx.sanctioned.tech`)
- Provider IDs on this version (26.6.3): **`google`**, **`linkedin-openid-connect`**
  (the legacy `linkedin` provider is gone — LinkedIn is OpenID Connect now).

> ⚠️ **Read [Who can get in?](#who-can-get-in) first.** Adding a social IdP means
> *anyone* with that provider can complete first-login and have an account created in
> the realm unless you constrain it. For a homelab this matters.

---

## How brokered login works here

1. User clicks **"Sign in with Google/LinkedIn"** on the Keycloak login page.
2. Keycloak redirects to the provider, the user authenticates there, and the provider
   redirects back to Keycloak's **broker endpoint**.
3. Keycloak runs the **first broker login** flow:
   - If a homelab user already exists with the same email → it offers to **link** the
     social identity to that account (after verifying ownership).
   - Otherwise it **creates a new** homelab user from the provider's profile.
4. From then on the user has a normal homelab session and SSO across all apps.

The redirect/callback URL Keycloak exposes per provider (you register these with
Google/LinkedIn) is:

```
Google:    https://keycloak.pdx.sanctioned.tech/realms/homelab/broker/google/endpoint
LinkedIn:  https://keycloak.pdx.sanctioned.tech/realms/homelab/broker/linkedin-openid-connect/endpoint
```

Secrets (the OAuth client id/secret each provider issues) live in `/opt/homelab/.env`
(pulled from Infisical), **never in git** — same rule as the OIDC client secrets. Suggested keys:

```
GOOGLE_OIDC_CLIENT_ID=...
GOOGLE_OIDC_CLIENT_SECRET=...
LINKEDIN_OIDC_CLIENT_ID=...
LINKEDIN_OIDC_CLIENT_SECRET=...
```

---

## Google

### 1. Create the OAuth client at Google

1. <https://console.cloud.google.com> → pick/create a project.
2. **APIs & Services → OAuth consent screen** → configure (External; add your email as
   a test user if you keep it in "Testing", or Publish it).
3. **APIs & Services → Credentials → Create credentials → OAuth client ID**
   - Application type: **Web application**
   - **Authorized redirect URI:**
     `https://keycloak.pdx.sanctioned.tech/realms/homelab/broker/google/endpoint`
4. Copy the **Client ID** and **Client secret** into `.env`
   (`GOOGLE_OIDC_CLIENT_ID` / `GOOGLE_OIDC_CLIENT_SECRET`).

### 2. Add the identity provider in Keycloak

**Admin UI:** Realm `homelab` → **Identity providers → Add provider → Google** →
paste Client ID + Secret → set **Default Scopes** = `openid email profile` →
(optional) **Hosted Domain** = your Google Workspace domain to lock it down → Save.

**Config-as-code (kcadm)** — run from `/opt/homelab`:

```bash
g(){ grep "^$1=" .env | cut -d= -f2-; }
KC(){ docker exec keycloak /opt/keycloak/bin/kcadm.sh "$@"; }
KC config credentials --server http://localhost:8080 --realm master \
  --user "$(g KEYCLOAK_ADMIN)" --password "$(g KEYCLOAK_ADMIN_PASSWORD)"

KC create identity-provider/instances -r homelab \
  -s alias=google -s providerId=google -s enabled=true \
  -s 'trustEmail=true' -s 'storeToken=false' \
  -s "config.clientId=$(g GOOGLE_OIDC_CLIENT_ID)" \
  -s "config.clientSecret=$(g GOOGLE_OIDC_CLIENT_SECRET)" \
  -s 'config.defaultScope=openid email profile' \
  -s 'config.syncMode=IMPORT'
  # optional Workspace lock-down:  -s 'config.hostedDomain=yourcompany.com'
```

`trustEmail=true` is safe for Google (it returns a verified email), and skips the
homelab email-verification step on first login.

---

## LinkedIn

LinkedIn uses **"Sign In with LinkedIn using OpenID Connect"**.

### 1. Create the app at LinkedIn

1. <https://www.linkedin.com/developers/apps> → **Create app** (needs a LinkedIn Company Page).
2. **Products** tab → request **"Sign In with LinkedIn using OpenID Connect"** (grants
   the `openid`, `profile`, `email` scopes).
3. **Auth** tab → add **Authorized redirect URL:**
   `https://keycloak.pdx.sanctioned.tech/realms/homelab/broker/linkedin-openid-connect/endpoint`
4. Copy **Client ID** / **Client Secret** into `.env`
   (`LINKEDIN_OIDC_CLIENT_ID` / `LINKEDIN_OIDC_CLIENT_SECRET`).

### 2. Add the identity provider in Keycloak

**Admin UI:** Realm `homelab` → **Identity providers → Add provider → LinkedIn** →
paste Client ID + Secret → **Default Scopes** = `openid profile email` → Save.

**Config-as-code (kcadm):**

```bash
KC create identity-provider/instances -r homelab \
  -s alias=linkedin-openid-connect -s providerId=linkedin-openid-connect -s enabled=true \
  -s 'trustEmail=true' -s 'storeToken=false' \
  -s "config.clientId=$(g LINKEDIN_OIDC_CLIENT_ID)" \
  -s "config.clientSecret=$(g LINKEDIN_OIDC_CLIENT_SECRET)" \
  -s 'config.defaultScope=openid profile email' \
  -s 'config.syncMode=IMPORT'
```

---

## Who can get in?

By default a social IdP will **create a homelab account for anyone** who can sign in
with that provider. Pick a containment strategy:

- **Google Workspace only** — set `config.hostedDomain=yourcompany.com`. Only that
  workspace's accounts are accepted. Best lock-down for Google. (LinkedIn has no
  equivalent domain filter.)
- **Link-only, no auto-create** — customise the *First broker login* flow so it only
  links to an existing homelab user and never auto-registers. Then pre-create the
  intended users (or let them register once via password) and social just links.
- **Authorize at the app, not the realm** — let accounts be created, but gate each
  app on a homelab **group/role** (e.g. require group `homelab-users`). New brokered
  users land with no group → no access until you add them.

For a small homelab, **Google + `hostedDomain`** (if you have Workspace) or the
**link-only flow** are the usual choices. Don't expose LinkedIn broadly without one of
the above — anyone with a LinkedIn account could otherwise self-provision.

---

## Make it rebuild-safe (config-as-code)

Mirror how OIDC clients are handled in [`realm-homelab.json`](realm-homelab.json):
the **non-secret** IdP config can be committed, with the secret replaced by a
placeholder, and the real secret applied after import.

- Either bake an `identityProviders` entry into `realm-homelab.json` with
  `"clientSecret": "REPLACE_AFTER_IMPORT"` and set the real value post-import via
  `kcadm update identity-provider/instances/<alias>`,
- **or** (cleaner, matches `configure-smtp.sh` / `configure-passkeys.sh`) wrap the
  `kcadm create` calls above in an idempotent `configure-social.sh` helper that reads
  the `*_OIDC_CLIENT_*` values from `.env` and is re-run as part of the realm-rebuild
  sequence. The helper keeps secrets out of git entirely.

> Want the helper scaffolded? Ask and it can be added as `configure-social.sh`
> alongside the other `configure-*.sh` scripts, plus the `.env.example` keys.

---

## Testing & gotchas

- **Redirect URI must match exactly** (scheme, host, `/realms/homelab/broker/<alias>/endpoint`,
  no trailing slash). The #1 cause of `redirect_uri_mismatch`.
- WebAuthn/social both need HTTPS — already satisfied by Traefik TLS + `KC_HOSTNAME`.
- After adding the provider, the buttons appear automatically on the homelab login
  page (the `identity-provider-redirector` execution is already in the browser flow).
- **Email collisions / linking:** if a brokered email matches an existing homelab user,
  Keycloak runs the "account already exists" path — the user proves ownership (email or
  password) and the identities are linked. `trustEmail=true` smooths Google's case.
- **Attribute mappers:** add IdP mappers (UI: provider → Mappers) if you need to map
  groups/claims from the provider onto homelab roles/groups.
- These social logins are the *primary* credential; the `browser-passkeys` 2FA-skip
  logic only applies to passkey logins, so social logins follow the normal 2FA rules.
