-- ============================================================================
-- Append-only writer for the AI audit record (todos.md #40).
--
-- The export (export-audit.sh) connects as THIS user, never the ClickHouse
-- admin, so a compromised or buggy export path cannot erase the record it is
-- meant to protect. It can create the schema and write, but is DENIED
-- DELETE / TRUNCATE / ALTER (which covers ALTER … DELETE mutations) / DROP —
-- the same REVOKE-DELETE posture as exampleapp_delivery (#27). Only a human
-- holding the ClickHouse admin credential can prune the record.
--
-- Lives in ClickHouse's SQL access store (persists in /var/lib/clickhouse/access;
-- enabled by CLICKHOUSE_DEFAULT_ACCESS_MANAGEMENT=1), NOT from .env — only the
-- password is carried in Infisical as CLICKHOUSE_AI_AUDIT_WRITER_PASSWORD.
--
-- Apply on a fresh host (substitute the Infisical password):
--   PW=$(grep '^CLICKHOUSE_AI_AUDIT_WRITER_PASSWORD=' /opt/homelab/.env | cut -d= -f2-)
--   sed "s/__PW__/$PW/" writer-role.sql | docker exec -i clickhouse clickhouse-client --multiquery
-- Rotate:
--   ALTER USER ai_audit_writer IDENTIFIED WITH sha256_password BY '<new>';
-- ============================================================================

CREATE USER IF NOT EXISTS ai_audit_writer IDENTIFIED BY '__PW__';

-- Create (self-heal the schema on a fresh host) + write, but no erase verbs.
GRANT CREATE DATABASE ON ai_governance.* TO ai_audit_writer;
GRANT CREATE TABLE, CREATE VIEW ON ai_governance.* TO ai_audit_writer;
GRANT INSERT, SELECT, OPTIMIZE ON ai_governance.* TO ai_audit_writer;

-- Read-only on the Langfuse source it harvests from, and the parts table it
-- uses to report the record's on-disk size.
GRANT SELECT ON default.traces TO ai_audit_writer;
GRANT SELECT ON default.observations TO ai_audit_writer;
GRANT SELECT ON system.parts TO ai_audit_writer;

-- Explicitly NOT granted (the point of this file): DELETE, TRUNCATE, ALTER, DROP.
