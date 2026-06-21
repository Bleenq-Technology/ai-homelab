#!/usr/bin/env bash
# Create the `jellyfin` OIDC client in the homelab realm for Jellyfin SSO via the
# 9p4 jellyfin-plugin-sso (Jellyfin runs on **stor**). The plugin's OIDC callback is
# https://jellyfin.pdx.sanctioned.tech/sso/OID/redirect/<provider-name> — we register
# provider name "keycloak". Adds a "groups" claim mapper (the plugin can map
# Keycloak groups/roles to Jellyfin admin/access). Idempotent.
#
# Like provision-nextcloud-client.sh, the secret is NOT written to jarvis .env —
# Jellyfin lives on stor and is configured via the SSO plugin's settings page. Read
# the secret from the Keycloak admin console (Clients -> jellyfin -> Credentials),
# or this script prints it to stderr. Sanitized client rep -> stdout for realm-homelab.json.
#
# Run from the deploy host:  ./core/keycloak/provision-jellyfin-client.sh
set -euo pipefail
cd "$(dirname "$0")/../.."

O="https://jellyfin.pdx.sanctioned.tech"

g(){ grep "^$1=" .env | cut -d= -f2- | sed -E "s/^['\"]//;s/['\"]\$//"; }
KC(){ docker exec keycloak /opt/keycloak/bin/kcadm.sh "$@"; }

KC config credentials --server http://localhost:8080 --realm master \
  --user "$(g KEYCLOAK_ADMIN)" --password "$(g KEYCLOAK_ADMIN_PASSWORD)" >/dev/null

CID=$(KC get clients -r homelab -q clientId=jellyfin --fields id --format csv --noquotes 2>/dev/null || true)
if [ -z "$CID" ]; then
  KC create clients -r homelab \
    -s clientId=jellyfin -s enabled=true -s protocol=openid-connect \
    -s publicClient=false -s standardFlowEnabled=true -s directAccessGrantsEnabled=false \
    -s "redirectUris=[\"$O/sso/OID/redirect/keycloak\",\"$O/sso/OID/r/keycloak\",\"$O/*\"]" \
    -s "webOrigins=[\"$O\"]" \
    -s "attributes.\"post.logout.redirect.uris\"=\"$O/*\"" >/dev/null
  CID=$(KC get clients -r homelab -q clientId=jellyfin --fields id --format csv --noquotes)
  echo "created client jellyfin ($CID)" >&2
else
  echo "client jellyfin already exists ($CID)" >&2
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
echo "CLIENT SECRET (enter in the Jellyfin SSO plugin config): $SECRET" >&2

KC get "clients/$CID" -r homelab \
  | python3 -c 'import sys,json; c=json.load(sys.stdin); c["secret"]="REPLACE_AFTER_IMPORT"; print(json.dumps(c))'
