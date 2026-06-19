#!/usr/bin/env bash
# Enable passkeys (passwordless WebAuthn) on the `homelab` realm and harden the
# WebAuthn Passwordless Policy for them. Idempotent — safe to re-run (e.g. after a
# realm rebuild on a new host).
#
# Passkeys are GA / enabled by default in Keycloak 26.4+ (this deploy is 26.6.3),
# so no KC_FEATURES flag is needed. On 26.0–26.3, passkeys was a preview feature —
# set `KC_FEATURES: passkeys` on the service first if you ever pin one of those.
# Run from the deploy host:  ./core/keycloak/configure-passkeys.sh
#
# What this does:
#   - RP ID = the parent ${DOMAIN}, so one passkey works across every *.${DOMAIN}
#     subdomain (Grafana, Open WebUI, etc.), not just keycloak.${DOMAIN}.
#   - Require resident key = Yes + user verification = required  -> true discoverable
#     passkeys with biometric/PIN (iPhone Face ID, Touch ID, Windows Hello, YubiKey).
#   - Authenticator attachment left unset so both platform authenticators AND
#     cross-device "hybrid" (scan a QR with your iPhone, approve with Face ID) work.
#   - Enables the `webauthn-register-passwordless` required action and flips the
#     "Enable Passkeys" switch (conditional + modal passkey UI on the login form).
#
# Note: kcadm won't echo the nested webAuthn policy back via `--fields`, so we apply
# a JSON file with `-f` (same pattern as configure-smtp.sh) and read the full realm
# to verify.
set -euo pipefail
cd "$(dirname "$0")/../.."   # core/keycloak -> deploy root (/opt/homelab, where .env lives)

g() { grep "^$1=" .env | cut -d= -f2- | sed -E "s/^['\"]//;s/['\"]\$//"; }
KC() { docker exec keycloak /opt/keycloak/bin/kcadm.sh "$@"; }

KC config credentials --server http://localhost:8080 --realm master \
  --user "$(g KEYCLOAK_ADMIN)" --password "$(g KEYCLOAK_ADMIN_PASSWORD)"

python3 - "$(g DOMAIN)" > /tmp/kc-passkeys.json <<'PY'
import sys, json
domain = sys.argv[1]
print(json.dumps({
    "webAuthnPolicyPasswordlessRpEntityName": "Bleenq Homelab",
    "webAuthnPolicyPasswordlessRpId": domain,
    "webAuthnPolicyPasswordlessSignatureAlgorithms": ["ES256", "RS256"],
    "webAuthnPolicyPasswordlessAttestationConveyancePreference": "none",
    "webAuthnPolicyPasswordlessAuthenticatorAttachment": "not specified",
    "webAuthnPolicyPasswordlessRequireResidentKey": "Yes",
    "webAuthnPolicyPasswordlessUserVerificationRequirement": "required",
    "webAuthnPolicyPasswordlessPasskeysEnabled": True,
}))
PY
docker cp /tmp/kc-passkeys.json keycloak:/tmp/kc-passkeys.json
KC update realms/homelab -f /tmp/kc-passkeys.json
rm -f /tmp/kc-passkeys.json

# Make sure users can actually enroll a passkey (idempotent).
KC update authentication/required-actions/webauthn-register-passwordless \
  -r homelab -s enabled=true -s defaultAction=false

echo "Keycloak passkeys enabled on realm 'homelab' (RP ID = $(g DOMAIN))."
echo "Users self-enroll at: https://keycloak.$(g DOMAIN)/realms/homelab/account/#/security/signing-in"
