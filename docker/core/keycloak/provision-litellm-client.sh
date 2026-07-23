#!/usr/bin/env bash
# ============================================================================
# Provision the Keycloak OIDC client for the **LiteLLM admin UI** SSO login.
#
# WHY: the admin UI (/ui) can mint and revoke every virtual key and read all
# spend, but it was reachable on the LAN gated only by the master key used as a
# password — the weakest link in the key-governance chain (docs/ai-governance.md).
# Native OIDC gives real per-user identity: you see WHO minted or revoked a key.
#
# LICENSING (verified in v1.89.1's ui_sso.py, not from docs): generic OIDC SSO is
# FREE while `LiteLLM_UserTable` holds <= 5 users, and REQUIRES a database
# (DATABASE_URL). Above 5 users it 403s and demands LITELLM_LICENSE. Each distinct
# Keycloak user who logs in becomes a row and counts toward the 5.
#   (A second, flat "Enterprise required" gate exists on /sso/debug/login — an
#    experimental debug route only; it does not affect the normal UI login.)
#
# Idempotent. Run on jarvis. Secret goes to Infisical, never to git.
#   ./provision-litellm-client.sh
# ============================================================================
set -euo pipefail
cd "$(dirname "$0")/../.." 2>/dev/null || cd /opt/homelab

REALM=homelab
CLIENT=litellm
DOMAIN_VAL="${DOMAIN:-$(grep -E '^DOMAIN=' .env 2>/dev/null | head -1 | cut -d= -f2-)}"
[[ -n "$DOMAIN_VAL" ]] || { echo "DOMAIN not resolvable (env or .env)"; exit 1; }
# LiteLLM redirects to {PROXY_BASE_URL}/sso/callback (ui_sso.py: sso_callback_route).
REDIRECT="https://litellm.${DOMAIN_VAL}/sso/callback"

KC(){ docker exec keycloak /opt/keycloak/bin/kcadm.sh "$@"; }

# Authenticate kcadm (admin creds from .env, as the other provision-* scripts do).
KC config credentials --server http://localhost:8080 --realm master \
  --user "$(grep -E '^KEYCLOAK_ADMIN=' .env | cut -d= -f2-)" \
  --password "$(grep -E '^KEYCLOAK_ADMIN_PASSWORD=' .env | cut -d= -f2-)" >/dev/null

CID=$(KC get clients -r "$REALM" -q clientId=$CLIENT --fields id --format csv --noquotes 2>/dev/null | tr -d '\r' || true)
if [[ -z "$CID" ]]; then
  # Confidential client: standard auth-code flow, no direct grants, exact redirect
  # (Keycloak 26 rejects wildcard subdomains — see todos.md #21).
  KC create clients -r "$REALM" \
    -s clientId=$CLIENT -s enabled=true -s protocol=openid-connect \
    -s publicClient=false -s standardFlowEnabled=true \
    -s directAccessGrantsEnabled=false -s serviceAccountsEnabled=false \
    -s "redirectUris=[\"$REDIRECT\"]" \
    -s "webOrigins=[\"https://litellm.${DOMAIN_VAL}\"]" \
    -s 'attributes={"post.logout.redirect.uris":"+"}' >/dev/null
  CID=$(KC get clients -r "$REALM" -q clientId=$CLIENT --fields id --format csv --noquotes | tr -d '\r')
  echo "created Keycloak client '$CLIENT' ($CID)" >&2
else
  # Keep the redirect URI correct on re-runs (the usual cause of a broken SSO loop).
  KC update "clients/$CID" -r "$REALM" -s "redirectUris=[\"$REDIRECT\"]" >/dev/null
  echo "client '$CLIENT' exists ($CID) — redirect URI re-asserted" >&2
fi

SECRET=$(KC get "clients/$CID/client-secret" -r "$REALM" \
  | python3 -c 'import sys,json; print(json.load(sys.stdin)["value"])')

# Infisical is the source of truth; never hand-edit .env (CLAUDE.md).
./push-secret.sh LITELLM_OIDC_CLIENT_SECRET "$SECRET" >/dev/null
echo "LITELLM_OIDC_CLIENT_SECRET -> Infisical (value not echoed)" >&2
echo "redirect URI: $REDIRECT" >&2
echo "next: ./pull-secrets.sh && docker compose -f compose.yml up -d litellm" >&2
