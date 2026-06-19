#!/usr/bin/env bash
# ============================================================================
# Set/rotate ONE secret in Infisical (homelab/prod) using the jarvis-deploy
# machine identity — the WRITE counterpart to pull-secrets.sh. The secret
# VALUE is never printed (only its length, for a sanity check).
#
#   ./push-secret.sh KEY VALUE     # set KEY to VALUE
#   ./push-secret.sh KEY           # set KEY from its current ./.env value
#
# Auth (machine-identity client id/secret) lives in ./.infisical-auth — the same
# bootstrap file pull-secrets.sh uses (kept OUT of git and Infisical).
# After pushing, the value is durable: the next ./pull-secrets.sh keeps it.
# ============================================================================
set -uo pipefail
cd "$(dirname "$0")"

KEY="${1:?usage: push-secret.sh KEY [VALUE]   (VALUE omitted = read from ./.env)}"
VALUE="${2:-}"
if [[ -z "$VALUE" ]]; then
  VALUE=$(grep -E "^${KEY}=" ./.env 2>/dev/null | cut -d= -f2- | tr -d '\r')
fi
[[ -n "$VALUE" ]] || { echo "no value for ${KEY} (pass it as arg 2 or set it in ./.env)" >&2; exit 1; }

[[ -f ./.infisical-auth ]] || { echo "missing ./.infisical-auth (machine-identity bootstrap)" >&2; exit 1; }
# shellcheck disable=SC1091
source ./.infisical-auth

TOKEN=$(infisical login --method=universal-auth \
  --client-id="$INFISICAL_CLIENT_ID" --client-secret="$INFISICAL_CLIENT_SECRET" \
  --domain="$INFISICAL_DOMAIN" --plain --silent)
[[ -n "$TOKEN" ]] || { echo "infisical login failed" >&2; exit 1; }

# Set (creates or updates). Suppress the CLI's value-revealing table — report status only.
if infisical secrets set "${KEY}=${VALUE}" \
     --projectId="$INFISICAL_PROJECT_ID" --env="${INFISICAL_ENV:-prod}" \
     --domain="$INFISICAL_DOMAIN" --token="$TOKEN" >/dev/null 2>&1; then
  RB=$(infisical secrets get "$KEY" --plain \
     --projectId="$INFISICAL_PROJECT_ID" --env="${INFISICAL_ENV:-prod}" \
     --domain="$INFISICAL_DOMAIN" --token="$TOKEN" 2>/dev/null)
  if [[ "$RB" == "$VALUE" ]]; then
    echo "✓ ${KEY} set in Infisical (${INFISICAL_ENV:-prod}); value length ${#VALUE}"
  else
    echo "✗ ${KEY} written but read-back did not match" >&2; exit 1
  fi
else
  echo "✗ failed to set ${KEY} (does the machine identity have write permission?)" >&2; exit 1
fi
