# traefik-forward-auth
**Purpose:** Keycloak OIDC bridge providing SSO forward-auth for services with no native OIDC.
**URL:** internal / no UI (auth endpoint only, service port 4181)
**Auth:** Keycloak OIDC, client `oauth2-proxy`, realm `homelab`
**Image:** thomseddon/traefik-forward-auth:2.2.0
**Networks / data:** `proxy` (external); no volumes

## Setup as deployed
- No router of its own — exposed only as a Traefik service on port `4181` and consumed by the `sso@file` / `secure-sso@file` forwardAuth middlewares (defined in `traefik/config/dynamic.yml`).
- Gates Prometheus, Alertmanager, SearXNG, and ComfyUI via those middlewares.
- Single shared cookie on `.${DOMAIN}` (`COOKIE_DOMAIN`) gives single-sign-on across every gated app.
- Env: `DEFAULT_PROVIDER=oidc`, `PROVIDERS_OIDC_ISSUER_URL=https://keycloak.${DOMAIN}/realms/homelab`, `PROVIDERS_OIDC_CLIENT_ID=oauth2-proxy`, `PROVIDERS_OIDC_CLIENT_SECRET=${OAUTH2_PROXY_CLIENT_SECRET}`, `SECRET=${TFA_SECRET}`, `AUTH_HOST=""`, `LOG_LEVEL=warn`.
- The OAuth callback (`/_oauth`) is handled by the same forwardAuth middleware — no extra router needed.

## Issues & Fixes

**Symptom:** An unauthenticated browser request to a gated app returned HTTP 401 and stopped, instead of redirecting to the Keycloak login.
**Fix:** Use traefik-forward-auth, whose auth endpoint returns a 307 that Traefik's forwardAuth relays to the browser. (oauth2-proxy only returned 302 on /oauth2/start, and Traefik's `errors` middleware downgraded that to 401.)

**Symptom:** Keycloak returned "Invalid parameter: redirect_uri" after the redirect.
**Fix:** Register explicit per-host redirect URIs `https://<host>.pdx.sanctioned.tech/_oauth` on the Keycloak client — Keycloak 26 does not accept a wildcard in the subdomain (e.g. `https://*.pdx.sanctioned.tech/_oauth`).

## Secrets
- `.env` keys: `OAUTH2_PROXY_CLIENT_SECRET` (Keycloak client secret), `TFA_SECRET` (cookie signing secret), `DOMAIN`.
- Nothing sensitive is committed to git.
