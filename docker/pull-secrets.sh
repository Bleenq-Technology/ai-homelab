#!/usr/bin/env bash
# ============================================================================
# Pull all secrets from Infisical into ./.env before `docker compose up`.
# Auth (machine-identity client id/secret) lives in ./.infisical-auth — a
# bootstrap file kept OUT of git and Infisical (see core/infisical/README.md).
#
#   ./pull-secrets.sh && docker compose -f compose.yml up -d
# ============================================================================
set -euo pipefail
cd "$(dirname "$0")"

if [[ ! -f ./.infisical-auth ]]; then
  echo "missing ./.infisical-auth (machine-identity bootstrap) — see core/infisical/README.md" >&2
  exit 1
fi
# shellcheck disable=SC1091
source ./.infisical-auth

TOKEN=$(infisical login --method=universal-auth \
  --client-id="$INFISICAL_CLIENT_ID" --client-secret="$INFISICAL_CLIENT_SECRET" \
  --domain="$INFISICAL_DOMAIN" --plain --silent)

umask 077
# Infisical CLI >= 0.38 wraps every exported value in single quotes
# (KEY='value'). docker compose strips them at interpolation, so containers
# keep working — but every RAW reader breaks silently: grep|cut scripts,
# `docker run --env-file`, and curl auth tests all see the quotes as part of
# the value (this manufactured the phantom "credential drift" of TODO #24).
# Strip the wrapping quotes so .env stays raw values, as everything expects.
# (Caveat: a secret whose value itself starts AND ends with a single quote
# would be over-stripped — don't create those.)
infisical export --format=dotenv \
  --projectId="$INFISICAL_PROJECT_ID" --env="${INFISICAL_ENV:-prod}" \
  --domain="$INFISICAL_DOMAIN" --token="$TOKEN" \
  | sed -E "s/^([A-Za-z_][A-Za-z0-9_]*)='(.*)'$/\1=\2/" > .env

echo "pulled $(grep -cE '^[A-Za-z_]' .env) secrets from Infisical (${INFISICAL_ENV:-prod}) -> .env"

# Keep this host's GHCR pull credential in sync with the rolled read-only PAT
# (todos #35). `.env` alone does NOT authenticate docker — the daemon reads the
# invoking user's ~/.docker/config.json — so log in here from the just-pulled
# values. Read-only PAT (pull, not push) is the right hygiene for a host cred.
# Rolling the key is now: push-secret.sh GHCR_READONLY_PAT <new> && ./pull-secrets.sh.
# NON-FATAL: a login blip must not fail the secrets pull (set -e is active), so || warn.
if command -v docker >/dev/null 2>&1 && grep -q '^GHCR_READONLY_PAT=' .env; then
  ghcr_pat=$(grep -E '^GHCR_READONLY_PAT=' .env | head -1 | cut -d= -f2-)
  ghcr_user=$(grep -E '^GHCR_USERNAME=' .env | head -1 | cut -d= -f2-)
  if [[ -n "$ghcr_pat" ]] && printf '%s' "$ghcr_pat" | docker login ghcr.io -u "${ghcr_user:-bleenq-paulv}" --password-stdin >/dev/null 2>&1; then
    echo "ghcr.io docker login refreshed (user ${ghcr_user:-bleenq-paulv})"
  else
    echo "WARN: ghcr.io docker login skipped/failed — 'docker pull ghcr.io/...' may need a manual login" >&2
  fi
fi
