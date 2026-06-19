#!/usr/bin/env bash
# Make passkey logins skip the OTP/2FA step, mirroring the Keycloak 26.4+ default
# browser flow. Keycloak's built-in `browser` flow can't be edited in place, so we
# duplicate it to `browser-passkeys`, drop a "Condition - credential" into its
# "Browser - Conditional OTP" subflow (skip OTP when a passkey was the primary
# credential), and bind it as the realm browser flow. Idempotent — safe to re-run.
#
# Run from the deploy host:  ./core/keycloak/add-passkey-2fa-skip.sh
set -euo pipefail
cd "$(dirname "$0")/../.."

g() { grep "^$1=" .env | cut -d= -f2- | sed -E "s/^['\"]//;s/['\"]\$//"; }
KC() { docker exec keycloak /opt/keycloak/bin/kcadm.sh "$@"; }

FLOW=browser-passkeys

KC config credentials --server http://localhost:8080 --realm master \
  --user "$(g KEYCLOAK_ADMIN)" --password "$(g KEYCLOAK_ADMIN_PASSWORD)" >/dev/null

# 1. Duplicate the built-in browser flow (skip if the copy already exists).
if ! KC get authentication/flows -r homelab 2>/dev/null \
     | python3 -c "import sys,json; sys.exit(0 if any(f['alias']=='$FLOW' for f in json.load(sys.stdin)) else 1)"; then
  echo "Duplicating built-in 'browser' flow -> '$FLOW'..."
  KC create authentication/flows/browser/copy -r homelab -b "{\"newName\":\"$FLOW\"}"
else
  echo "Flow '$FLOW' already exists — reusing."
fi

# 2. Find the copied "Browser - Conditional OTP" subflow's alias, and whether the
#    conditional-credential execution is already present in it.
read -r SUBFLOW HAVE CFGID <<EOF
$(KC get "authentication/flows/$FLOW/executions" -r homelab 2>/dev/null | python3 -c '
import sys, json
ex = json.load(sys.stdin)
sub = next(e["displayName"] for e in ex if e.get("authenticationFlow") and e["displayName"].endswith("Browser - Conditional OTP"))
cc  = next((e for e in ex if e.get("providerId")=="conditional-credential"), None)
print(sub.replace(" ", "%20"), "1" if cc else "0", (cc or {}).get("authenticationConfig",""))
')
EOF

# 3. Add the conditional-credential execution if missing.
if [ "$HAVE" = "0" ]; then
  echo "Adding 'Condition - credential' to the OTP subflow..."
  KC create "authentication/flows/$SUBFLOW/executions/execution" -r homelab \
    -s provider=conditional-credential
fi

# 4. Resolve its id, set REQUIRED, and lift it above the OTP Form.
EID=$(KC get "authentication/flows/$SUBFLOW/executions" -r homelab 2>/dev/null \
  | python3 -c 'import sys,json; print(next(e["id"] for e in json.load(sys.stdin) if e.get("providerId")=="conditional-credential"))')
KC update "authentication/flows/$SUBFLOW/executions" -r homelab \
  -b "{\"id\":\"$EID\",\"requirement\":\"REQUIRED\"}"
KC create "authentication/executions/$EID/raise-priority" -r homelab >/dev/null 2>&1 || true

# 5. (Re)apply config: included=false -> condition is true only when NONE of the
#    listed credentials was used, so OTP runs for password logins and is skipped
#    after a passkey (webauthn-passwordless) login.
CFG='{"alias":"passkey-skips-2fa","config":{"credentials":"[\"webauthn-passwordless\"]","included":"false"}}'
if [ -z "$CFGID" ]; then
  KC create "authentication/executions/$EID/config" -r homelab -b "$CFG"
else
  KC update "authentication/config/$CFGID" -r homelab -b "$CFG"
fi

# 6. Bind the custom flow as the realm browser flow.
KC update realms/homelab -r homelab -s browserFlow="$FLOW"

echo "Done. Realm browser flow = '$FLOW'; OTP is skipped after a passkey login."
