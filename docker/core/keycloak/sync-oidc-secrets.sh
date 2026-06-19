#!/usr/bin/env bash
# Sync Keycloak OIDC client secrets -> Infisical -> .env, then recreate the apps.
#
# Keycloak is the source of truth for confidential-client secrets. This pushes the
# current values into Infisical (so pull-secrets.sh produces a COMPLETE .env) and
# re-syncs. Run after rotating any client secret, or to repair drift. Idempotent.
#
#   ./core/keycloak/sync-oidc-secrets.sh        # run from /opt/homelab
set -euo pipefail
cd "$(dirname "$0")/../.."   # core/keycloak -> /opt/homelab

# Keycloak clientId -> Infisical / .env key
PAIRS="grafana:GRAFANA_OIDC_CLIENT_SECRET
langfuse:LANGFUSE_OIDC_CLIENT_SECRET
openwebui:OPENWEBUI_OIDC_CLIENT_SECRET
oauth2-proxy:OAUTH2_PROXY_CLIENT_SECRET
minio:MINIO_OIDC_CLIENT_SECRET"

g(){ grep "^$1=" .env | cut -d= -f2- | sed -E "s/^['\"]//;s/['\"]\$//"; }
KC(){ docker exec keycloak /opt/keycloak/bin/kcadm.sh "$@"; }

# shellcheck disable=SC1091
source ./.infisical-auth
TOKEN=$(infisical login --method=universal-auth \
  --client-id="$INFISICAL_CLIENT_ID" --client-secret="$INFISICAL_CLIENT_SECRET" \
  --domain="$INFISICAL_DOMAIN" --plain --silent)

KC config credentials --server http://localhost:8080 --realm master \
  --user "$(g KEYCLOAK_ADMIN)" --password "$(g KEYCLOAK_ADMIN_PASSWORD)" >/dev/null

echo "Pushing Keycloak client secrets into Infisical (${INFISICAL_ENV:-prod})..."
while IFS=: read -r client key; do
  [ -z "$client" ] && continue
  cid=$(KC get clients -r homelab -q clientId="$client" --fields id --format csv --noquotes)
  sec=$(KC get "clients/$cid/client-secret" -r homelab \
        | python3 -c 'import sys,json;print(json.load(sys.stdin)["value"])')
  infisical secrets set "$key=$sec" \
    --projectId="$INFISICAL_PROJECT_ID" --env="${INFISICAL_ENV:-prod}" \
    --domain="$INFISICAL_DOMAIN" --token="$TOKEN" --path="/" >/dev/null
  echo "  ✓ $client -> $key (len=${#sec})"
done <<< "$PAIRS"

echo "Re-pulling .env from Infisical..."
./pull-secrets.sh

echo "Verifying keys landed in .env..."
miss=0
while IFS=: read -r client key; do
  [ -z "$client" ] && continue
  v=$(g "$key"); [ -z "$v" ] && { echo "  ✗ $key MISSING"; miss=1; } || echo "  ✓ $key (len=${#v})"
done <<< "$PAIRS"
[ "$miss" = 0 ] || { echo "Some keys missing from .env — check Infisical path/env. NOT recreating."; exit 1; }

echo "Recreating OIDC apps so they pick up durable secrets..."
docker compose -f compose.yml up -d grafana langfuse openwebui oauth2-proxy minio
echo "Done."
