#!/usr/bin/env bash
# One-shot: create the `minio` OIDC client in the homelab realm (console SSO),
# write its secret to .env (MINIO_OIDC_CLIENT_SECRET), and print the sanitized
# client representation (secret -> REPLACE_AFTER_IMPORT) for baking into
# realm-homelab.json. Idempotent: reuses the client if it already exists.
#
# Run from the deploy host:  ./core/keycloak/provision-minio-client.sh
set -euo pipefail
cd "$(dirname "$0")/../.."

g(){ grep "^$1=" .env | cut -d= -f2- | sed -E "s/^['\"]//;s/['\"]\$//"; }
KC(){ docker exec keycloak /opt/keycloak/bin/kcadm.sh "$@"; }

KC config credentials --server http://localhost:8080 --realm master \
  --user "$(g KEYCLOAK_ADMIN)" --password "$(g KEYCLOAK_ADMIN_PASSWORD)" >/dev/null

CID=$(KC get clients -r homelab -q clientId=minio --fields id --format csv --noquotes 2>/dev/null || true)
if [ -z "$CID" ]; then
  KC create clients -r homelab \
    -s clientId=minio -s enabled=true -s protocol=openid-connect \
    -s publicClient=false -s standardFlowEnabled=true -s directAccessGrantsEnabled=false \
    -s 'redirectUris=["https://minio.pdx.sanctioned.tech/oauth_callback","https://minio.pdx.sanctioned.tech/*"]' \
    -s 'webOrigins=["https://minio.pdx.sanctioned.tech"]' \
    -s 'attributes."post.logout.redirect.uris"="https://minio.pdx.sanctioned.tech/*"' >/dev/null
  CID=$(KC get clients -r homelab -q clientId=minio --fields id --format csv --noquotes)
  echo "created client minio ($CID)" >&2
else
  echo "client minio already exists ($CID)" >&2
fi

SECRET=$(KC get "clients/$CID/client-secret" -r homelab 2>/dev/null \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)["value"])')

# upsert MINIO_OIDC_CLIENT_SECRET in .env (no value echoed)
if grep -q '^MINIO_OIDC_CLIENT_SECRET=' .env; then
  sed -i "s|^MINIO_OIDC_CLIENT_SECRET=.*|MINIO_OIDC_CLIENT_SECRET=${SECRET}|" .env
else
  printf 'MINIO_OIDC_CLIENT_SECRET=%s\n' "$SECRET" >> .env
fi
echo "MINIO_OIDC_CLIENT_SECRET written to .env" >&2

# print sanitized client representation for realm-homelab.json (secret scrubbed)
KC get "clients/$CID" -r homelab 2>/dev/null \
  | python3 -c 'import sys,json; c=json.load(sys.stdin); c["secret"]="REPLACE_AFTER_IMPORT"; print(json.dumps(c))'
