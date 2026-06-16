#!/usr/bin/env bash
# Configure the `homelab` realm's SMTP (Mailjet) and enable password reset +
# email verification. Idempotent — safe to re-run (e.g. after a realm rebuild).
#
# Reads SMTP_* and the Keycloak admin creds from /opt/homelab/.env (pulled from
# Infisical). Run from the deploy host:  ./core/keycloak/configure-smtp.sh
#
# Note: kcadm can't set the smtpServer map via `-s key.subkey=...`, and `--fields
# smtpServer` won't echo a nested map back — so we apply a JSON file with `-f`.
set -euo pipefail
cd "$(dirname "$0")/../../.."   # -> /opt/homelab (where .env lives)

g() { grep "^$1=" .env | cut -d= -f2- | sed -E "s/^['\"]//;s/['\"]\$//"; }
KC() { docker exec keycloak /opt/keycloak/bin/kcadm.sh "$@"; }

KC config credentials --server http://localhost:8080 --realm master \
  --user "$(g KEYCLOAK_ADMIN)" --password "$(g KEYCLOAK_ADMIN_PASSWORD)"

python3 - "$(g SMTP_HOST)" "$(g SMTP_PORT)" "$(g SMTP_FROM)" "$(g SMTP_FROM_NAME)" \
          "$(g SMTP_USER)" "$(g SMTP_PASSWORD)" > /tmp/kc-smtp.json <<'PY'
import sys, json
h, p, frm, disp, user, pw = sys.argv[1:7]
print(json.dumps({
    "smtpServer": {
        "host": h, "port": p, "from": frm, "fromDisplayName": disp,
        "ssl": "false", "starttls": "true", "auth": "true",
        "user": user, "password": pw,
    },
    "resetPasswordAllowed": True,
    "verifyEmail": True,
}))
PY
docker cp /tmp/kc-smtp.json keycloak:/tmp/kc-smtp.json
KC update realms/homelab -f /tmp/kc-smtp.json
rm -f /tmp/kc-smtp.json
echo "Keycloak SMTP configured (Mailjet); password reset + email verification enabled."
