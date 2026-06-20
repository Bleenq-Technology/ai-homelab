#!/usr/bin/env bash
# One-shot: create the `homarr` OIDC client in the homelab realm (Homarr native
# SSO at https://home.pdx.sanctioned.tech), add a "groups" claim mapper so
# Keycloak group membership flows to Homarr (AUTH_OIDC_GROUPS_ATTRIBUTE=groups)
# for role/admin mapping, write the secret to .env (HOMARR_OIDC_CLIENT_SECRET),
# and print the sanitized client representation (secret -> REPLACE_AFTER_IMPORT)
# for baking into realm-homelab.json. Idempotent: reuses the client/mapper if
# they already exist.
#
# Adapted from provision-minio-client.sh (the canonical client-provisioning template).
# Run from the deploy host:  ./core/keycloak/provision-homarr-client.sh
set -euo pipefail
cd "$(dirname "$0")/../.."

REDIRECT="https://home.pdx.sanctioned.tech/api/auth/callback/oidc"   # Homarr's fixed OIDC callback path
ORIGIN="https://home.pdx.sanctioned.tech"

g(){ grep "^$1=" .env | cut -d= -f2- | sed -E "s/^['\"]//;s/['\"]\$//"; }
KC(){ docker exec keycloak /opt/keycloak/bin/kcadm.sh "$@"; }

KC config credentials --server http://localhost:8080 --realm master \
  --user "$(g KEYCLOAK_ADMIN)" --password "$(g KEYCLOAK_ADMIN_PASSWORD)" >/dev/null

CID=$(KC get clients -r homelab -q clientId=homarr --fields id --format csv --noquotes 2>/dev/null || true)
if [ -z "$CID" ]; then
  KC create clients -r homelab \
    -s clientId=homarr -s enabled=true -s protocol=openid-connect \
    -s publicClient=false -s standardFlowEnabled=true -s directAccessGrantsEnabled=false \
    -s "redirectUris=[\"$REDIRECT\",\"$ORIGIN/*\"]" \
    -s "webOrigins=[\"$ORIGIN\"]" \
    -s "attributes.\"post.logout.redirect.uris\"=\"$ORIGIN/*\"" >/dev/null
  CID=$(KC get clients -r homelab -q clientId=homarr --fields id --format csv --noquotes)
  echo "created client homarr ($CID)" >&2
else
  echo "client homarr already exists ($CID)" >&2
fi

# Group Membership mapper -> emit a "groups" claim (what Homarr reads for role/admin mapping).
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

SECRET=$(KC get "clients/$CID/client-secret" -r homelab 2>/dev/null \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)["value"])')

# upsert HOMARR_OIDC_CLIENT_SECRET in .env (no value echoed)
if grep -q '^HOMARR_OIDC_CLIENT_SECRET=' .env; then
  sed -i "s|^HOMARR_OIDC_CLIENT_SECRET=.*|HOMARR_OIDC_CLIENT_SECRET=${SECRET}|" .env
else
  printf 'HOMARR_OIDC_CLIENT_SECRET=%s\n' "$SECRET" >> .env
fi
echo "HOMARR_OIDC_CLIENT_SECRET written to .env" >&2

# print sanitized client representation for realm-homelab.json (secret scrubbed)
KC get "clients/$CID" -r homelab 2>/dev/null \
  | python3 -c 'import sys,json; c=json.load(sys.stdin); c["secret"]="REPLACE_AFTER_IMPORT"; print(json.dumps(c))'
