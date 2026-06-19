#!/usr/bin/env bash
# One-shot: create a PERMANENT Keycloak master-realm admin (so automation/kcadm no
# longer depends on KC 26's expiring temporary bootstrap admin), store its creds in
# Infisical as KEYCLOAK_ADMIN / KEYCLOAK_ADMIN_PASSWORD, re-pull .env, and verify.
#
# Must be run while a working admin session is available (e.g. right after a Keycloak
# recreate, when the temporary bootstrap admin is still valid). Run from /opt/homelab:
#   ./core/keycloak/provision-permanent-admin.sh
set -euo pipefail
cd "$(dirname "$0")/../.."

NEW_USER="keycloak-admin"
NEW_EMAIL="keycloak-admin@vilevac.com"

g(){ grep "^$1=" .env | cut -d= -f2- | sed -E "s/^['\"]//;s/['\"]\$//"; }
KC(){ docker exec keycloak /opt/keycloak/bin/kcadm.sh "$@"; }

# Authenticate with the currently-valid admin (bootstrap temp admin).
KC config credentials --server http://localhost:8080 --realm master \
  --user "$(g KEYCLOAK_ADMIN)" --password "$(g KEYCLOAK_ADMIN_PASSWORD)" >/dev/null

# Strong, .env-safe password (hex, no shell/dotenv-hostile chars).
NEW_PASS=$(openssl rand -hex 24)

# Create (or reuse) the permanent admin user in the master realm.
if [ -z "$(KC get users -r master -q username="$NEW_USER" --fields id --format csv --noquotes 2>/dev/null)" ]; then
  KC create users -r master -s username="$NEW_USER" -s enabled=true \
    -s email="$NEW_EMAIL" -s emailVerified=true -s firstName=Keycloak -s lastName=Admin
  echo "created master user $NEW_USER"
else
  echo "master user $NEW_USER already exists — updating password/role"
fi
KC set-password -r master --username "$NEW_USER" --new-password "$NEW_PASS"
KC add-roles -r master --uusername "$NEW_USER" --rolename admin
echo "assigned 'admin' role to $NEW_USER"

# Store in Infisical so pull-secrets.sh carries it (and bootstrap env aligns).
source ./.infisical-auth
TOKEN=$(infisical login --method=universal-auth \
  --client-id="$INFISICAL_CLIENT_ID" --client-secret="$INFISICAL_CLIENT_SECRET" \
  --domain="$INFISICAL_DOMAIN" --plain --silent)
infisical secrets set "KEYCLOAK_ADMIN=$NEW_USER" "KEYCLOAK_ADMIN_PASSWORD=$NEW_PASS" \
  --projectId="$INFISICAL_PROJECT_ID" --env="${INFISICAL_ENV:-prod}" \
  --domain="$INFISICAL_DOMAIN" --token="$TOKEN" --path="/" >/dev/null
echo "stored KEYCLOAK_ADMIN/KEYCLOAK_ADMIN_PASSWORD in Infisical"

./pull-secrets.sh >/dev/null && echo ".env re-pulled"

# Verify the permanent admin can authenticate.
if KC config credentials --server http://localhost:8080 --realm master \
     --user "$(g KEYCLOAK_ADMIN)" --password "$(g KEYCLOAK_ADMIN_PASSWORD)" >/dev/null 2>&1; then
  echo "VERIFIED: permanent admin '$(g KEYCLOAK_ADMIN)' logs in via kcadm ✓"
else
  echo "VERIFICATION FAILED — check manually" >&2; exit 1
fi
