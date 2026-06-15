# Langfuse (web + worker)
**Purpose:** LLM observability / tracing (Langfuse v3).
**URL:** https://langfuse.pdx.sanctioned.tech (web UI); worker is internal (no UI)
**Auth:** native Keycloak OIDC (dedicated Keycloak provider)
**Image:** langfuse/langfuse:3 (web), langfuse/langfuse-worker:3 (worker)
**GPU:** no
**Networks / data:** langfuse-web: proxy, ai, data; langfuse-worker: ai, data. No bind mounts —
state lives in the backing services below.

This stack is **two services** sharing one env block via a YAML anchor (`&langfuse-env` on
`langfuse-web`, `*langfuse-env` on `langfuse-worker`). `langfuse-web` is the Next.js UI/API;
`langfuse-worker` processes background jobs and has no UI.

## Setup as deployed
Backing services (defined elsewhere in the data stack):
- **Postgres** DB `langfuse`: `DATABASE_URL=postgresql://langfuse:${LANGFUSE_DB_PASSWORD}@postgres:5432/langfuse`
- **ClickHouse** (with Keeper): `CLICKHOUSE_URL=http://clickhouse:8123`,
  `CLICKHOUSE_MIGRATION_URL=clickhouse://clickhouse:9000`, `CLICKHOUSE_USER`, `CLICKHOUSE_PASSWORD`
- **Redis** DB 5: `REDIS_CONNECTION_STRING=redis://:${REDIS_PASSWORD}@redis:6379/5`
- **MinIO** bucket `langfuse` for event uploads:
  - `LANGFUSE_S3_EVENT_UPLOAD_BUCKET=${LANGFUSE_S3_BUCKET}`
  - `LANGFUSE_S3_EVENT_UPLOAD_ENDPOINT=http://minio:9000`
  - `LANGFUSE_S3_EVENT_UPLOAD_ACCESS_KEY_ID=${MINIO_ROOT_USER}`
  - `LANGFUSE_S3_EVENT_UPLOAD_SECRET_ACCESS_KEY=${MINIO_ROOT_PASSWORD}`
  - `LANGFUSE_S3_EVENT_UPLOAD_REGION=auto`, `LANGFUSE_S3_EVENT_UPLOAD_FORCE_PATH_STYLE=true`

App / auth config:
- `NEXTAUTH_URL=https://langfuse.${DOMAIN}`, `NEXTAUTH_SECRET=${LANGFUSE_NEXTAUTH_SECRET}`
- `SALT=${LANGFUSE_SALT}`, `ENCRYPTION_KEY=${LANGFUSE_ENCRYPTION_KEY}`
- Keycloak SSO via the **dedicated Keycloak provider**:
  - `AUTH_KEYCLOAK_CLIENT_ID=langfuse`, `AUTH_KEYCLOAK_CLIENT_SECRET=${LANGFUSE_OIDC_CLIENT_SECRET}`
  - `AUTH_KEYCLOAK_ISSUER=https://keycloak.${DOMAIN}/realms/homelab`
  - `AUTH_KEYCLOAK_ALLOW_ACCOUNT_LINKING=true`
  - OIDC callback: `/api/auth/callback/keycloak`
- `langfuse-web` Traefik router on `websecure`, TLS, middleware `secure-chain@file`, backend port 3000.
- `langfuse-worker` depends-on order: `langfuse-web depends_on langfuse-worker`.

### First login
- Sign in via Keycloak; the account is provisioned on first login.

## Issues & Fixes

**Symptom:** https://langfuse.pdx.sanctioned.tech returned 502 even though the container was running and listening on :3000.
**Fix:** set `HOSTNAME=0.0.0.0` — langfuse-web is Next.js, which binds to `$HOSTNAME` and otherwise pinned itself to a single one of the container's networks (not the proxy network Traefik uses).

**Symptom:** SSO login failed with `error=Callback`; the logs showed `[next-auth][error][adapter_error_linkAccount]` and `PrismaClientValidationError: Unknown argument 'refresh_expires_in'`.
**Fix:** switch from the generic custom OIDC provider (`AUTH_CUSTOM_*`) to Langfuse's dedicated Keycloak provider (`AUTH_KEYCLOAK_*`, callback `/api/auth/callback/keycloak`) — it handles Keycloak's extra `refresh_expires_in` token field.

## Secrets
- `LANGFUSE_DB_PASSWORD`, `CLICKHOUSE_USER`, `CLICKHOUSE_PASSWORD`, `REDIS_PASSWORD`
- `MINIO_ROOT_USER`, `MINIO_ROOT_PASSWORD`, `LANGFUSE_S3_BUCKET`
- `LANGFUSE_NEXTAUTH_SECRET`, `LANGFUSE_SALT`, `LANGFUSE_ENCRYPTION_KEY`
- `LANGFUSE_OIDC_CLIENT_SECRET` — Keycloak client secret for the `langfuse` client.
- `DOMAIN`, `TZ`. All secrets come from `/opt/homelab/.env` (gitignored); nothing sensitive is committed.
