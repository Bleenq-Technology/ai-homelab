#!/usr/bin/env bash
# Create the `nextcloud` OIDC client in the homelab realm for Nextcloud SSO.
# Nextcloud runs on **stor** (not jarvis) via the user_oidc app; its callback is
# https://drive.pdx.sanctioned.tech/apps/user_oidc/code. Adds a "groups" claim
# mapper so Keycloak group membership can drive Nextcloud groups later. Idempotent.
#
# UNLIKE the other provision-*-client.sh scripts, the secret is NOT written to
# jarvis's .env/Infisical — the consuming app lives on stor. Apply it there:
#   occ user_oidc:provider Keycloak --clientid=nextcloud --clientsecret=<SECRET> \
#     --discoveryuri=https://keycloak.pdx.sanctioned.tech/realms/homelab/.well-known/openid-configuration \
#     --scope="openid email profile" --mapping-uid=preferred_username --unique-uid=0
# Prints the secret to stderr (to apply on stor) and the sanitized client rep to
# stdout (for baking into realm-homelab.json).
#
# Adapted from provision-homarr-client.sh. Run from the deploy host:
#   ./core/keycloak/provision-nextcloud-client.sh
set -euo pipefail
cd "$(dirname "$0")/../.."

ORIGIN="https://drive.pdx.sanctioned.tech"

g(){ grep "^$1=" .env | cut -d= -f2- | sed -E "s/^['\"]//;s/['\"]\$//"; }
KC(){ docker exec keycloak /opt/keycloak/bin/kcadm.sh "$@"; }

KC config credentials --server http://localhost:8080 --realm master \
  --user "$(g KEYCLOAK_ADMIN)" --password "$(g KEYCLOAK_ADMIN_PASSWORD)" >/dev/null

CID=$(KC get clients -r homelab -q clientId=nextcloud --fields id --format csv --noquotes 2>/dev/null || true)
if [ -z "$CID" ]; then
  KC create clients -r homelab \
    -s clientId=nextcloud -s enabled=true -s protocol=openid-connect \
    -s publicClient=false -s standardFlowEnabled=true -s directAccessGrantsEnabled=false \
    -s "redirectUris=[\"$ORIGIN/apps/user_oidc/code\",\"$ORIGIN/index.php/apps/user_oidc/code\",\"$ORIGIN/*\"]" \
    -s "webOrigins=[\"$ORIGIN\"]" \
    -s "attributes.\"post.logout.redirect.uris\"=\"$ORIGIN/*\"" >/dev/null
  CID=$(KC get clients -r homelab -q clientId=nextcloud --fields id --format csv --noquotes)
  echo "created client nextcloud ($CID)" >&2
else
  echo "client nextcloud already exists ($CID)" >&2
fi

HASMAP=$(KC get "clients/$CID/protocol-mappers/models" -r homelab --fields name --format csv --noquotes 2>/dev/null \
  | tr -d '"' | grep -Fx groups || true)
if [ -z "$HASMAP" ]; then
  KC create "clients/$CID/protocol-mappers/models" -r homelab \
    -s name=groups -s protocol=openid-connect -s protocolMapper=oidc-group-membership-mapper \
    -s 'config."claim.name"=groups' -s 'config."full.path"=false' \
    -s 'config."id.token.claim"=true' -s 'config."access.token.claim"=true' \
    -s 'config."userinfo.token.claim"=true' >/dev/null
  echo "added groups mapper" >&2
else
  echo "groups mapper already present" >&2
fi

SECRET=$(KC get "clients/$CID/client-secret" -r homelab | python3 -c 'import sys,json;print(json.load(sys.stdin)["value"])')
echo "CLIENT SECRET (apply on stor via occ user_oidc:provider): $SECRET" >&2

# sanitized client rep for realm-homelab.json (secret scrubbed)
KC get "clients/$CID" -r homelab \
  | python3 -c 'import sys,json; c=json.load(sys.stdin); c["secret"]="REPLACE_AFTER_IMPORT"; print(json.dumps(c))'
