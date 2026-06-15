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
infisical export --format=dotenv \
  --projectId="$INFISICAL_PROJECT_ID" --env="${INFISICAL_ENV:-prod}" \
  --domain="$INFISICAL_DOMAIN" --token="$TOKEN" > .env

echo "pulled $(grep -cE '^[A-Za-z_]' .env) secrets from Infisical (${INFISICAL_ENV:-prod}) -> .env"
