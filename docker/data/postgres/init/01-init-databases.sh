#!/bin/bash
# ============================================================================
# Creates one database + least-privilege role per dependent service.
# Runs once, on first init of an empty data directory (supabase/postgres image
# honours /docker-entrypoint-initdb.d). Passwords come from the container env,
# which is sourced from docker/.env — keep these names in sync with .env.
# ============================================================================
set -euo pipefail

create_db_and_role() {
  local db="$1" role="$2" pass="$3"
  echo "==> ensuring role '$role' and database '$db'"
  psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "postgres" <<-SQL
    DO \$\$
    BEGIN
      IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${role}') THEN
        CREATE ROLE ${role} LOGIN PASSWORD '${pass}';
      END IF;
    END
    \$\$;
SQL
  # CREATE DATABASE can't run inside the DO block / a transaction
  if ! psql -tAc "SELECT 1 FROM pg_database WHERE datname = '${db}'" | grep -q 1; then
    psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "postgres" \
      -c "CREATE DATABASE ${db} OWNER ${role};"
  fi
  psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "postgres" \
    -c "GRANT ALL PRIVILEGES ON DATABASE ${db} TO ${role};"
}

create_db_and_role keycloak  keycloak  "${KEYCLOAK_DB_PASSWORD}"
create_db_and_role netbox    netbox    "${NETBOX_DB_PASSWORD}"
create_db_and_role infisical infisical "${INFISICAL_DB_PASSWORD}"
create_db_and_role baserow   baserow   "${BASEROW_DB_PASSWORD}"
create_db_and_role langfuse  langfuse  "${LANGFUSE_DB_PASSWORD}"
create_db_and_role n8n       n8n       "${N8N_DB_PASSWORD}"
create_db_and_role firezone  firezone  "${FIREZONE_DB_PASSWORD:-change_me_firezone_db}"

echo "==> per-service databases ready"
