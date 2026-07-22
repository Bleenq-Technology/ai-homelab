#!/usr/bin/env bash
# ============================================================================
# Harvest the slim, long-lived AI audit record from Langfuse before its 14-day
# TTL deletes the source (todos.md #40).
#
# Runs entirely INSIDE ClickHouse as one INSERT ... SELECT. That is deliberate:
# prompt and response bodies are hashed in place and NEVER leave the database, so
# this script cannot leak the text it is summarising, and there is no round-trip
# of megabytes of prompts through a shell.
#
# IDEMPOTENT by design. The table is a ReplacingMergeTree keyed on trace_id, so
# re-running over an overlapping window replaces rather than duplicates — which
# is what lets us use a deliberately generous lookback. Missing a day is
# unrecoverable once the 14d TTL passes; double-counting a day costs nothing.
#
# Usage:  ./export-audit.sh [--publish] [LOOKBACK_DAYS]
# ============================================================================
set -uo pipefail

LOOKBACK="${2:-${LOOKBACK_DAYS:-3}}"
TEXTFILE_DIR="${TEXTFILE_DIR:-/var/lib/node_exporter/textfile}"
HERE="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="${HOMELAB_ENV:-/opt/homelab/.env}"
PUBLISH=0
[ "${1:-}" = "--publish" ] && PUBLISH=1

# Connect as the APPEND-ONLY writer, never the admin (todos.md #40). The writer
# can INSERT/SELECT/OPTIMIZE but is denied DELETE/TRUNCATE/ALTER/DROP, so a
# compromised or buggy export path cannot erase the audit record it is meant to
# protect — the same REVOKE-DELETE posture as exampleapp_delivery (#27). Only a
# human with the ClickHouse admin credential can prune it. If the password is
# missing we FAIL rather than silently falling back to admin: running the writer
# as admin would quietly defeat the whole point.
AUDIT_PW=$(grep -E '^CLICKHOUSE_AI_AUDIT_WRITER_PASSWORD=' "$ENV_FILE" 2>/dev/null | head -1 | cut -d= -f2-)
if [ -z "$AUDIT_PW" ]; then
  echo "[ERROR] CLICKHOUSE_AI_AUDIT_WRITER_PASSWORD not in $ENV_FILE — refusing to run as admin" >&2
  exit 1
fi
ch() { docker exec clickhouse clickhouse-client --user ai_audit_writer --password "$AUDIT_PW" "$@"; }

# Schema is idempotent (IF NOT EXISTS) — applying every run means a fresh host or
# a dropped table self-heals instead of failing silently for weeks. The writer
# holds CREATE (self-heal) but not DROP, so this can create but never clobber.
if [ -f "$HERE/schema.sql" ]; then
  docker exec -i clickhouse clickhouse-client --user ai_audit_writer --password "$AUDIT_PW" \
    --multiquery < "$HERE/schema.sql" \
    || { echo "[ERROR] schema apply failed" >&2; exit 1; }
fi

before=$(ch -q "SELECT count() FROM ai_governance.gateway_calls" 2>/dev/null | tr -d '[:space:]')
before=${before:-0}

# One observation per trace: aggregate first, otherwise a multi-observation trace
# fans out into duplicate audit rows with different token counts.
ch -q "
INSERT INTO ai_governance.gateway_calls
    (ts, system, model, trace_id, status, latency_ms,
     input_tokens, output_tokens, total_tokens, input_sha256, output_sha256)
SELECT
    t.timestamp AS ts,
    -- The alias tag LiteLLM stamps on every trace (litellm_settings
    -- .langfuse_default_tags). 'unattributed' is a REAL and important value: it
    -- means a call reached the gateway that we cannot tie to a system.
    --
    -- GOTCHA: arrayFirst returns an EMPTY STRING (not NULL) when nothing
    -- matches, so nullIf(...,'None') alone lets '' through and the rows land
    -- with a blank system instead of 'unattributed' — silently hiding the exact
    -- population this column exists to surface. Both sentinels must be mapped.
    multiIf(
      replaceOne(arrayFirst(x -> startsWith(x, 'user_api_key_alias:'), t.tags),
                 'user_api_key_alias:', '') IN ('', 'None'),
      'unattributed',
      replaceOne(arrayFirst(x -> startsWith(x, 'user_api_key_alias:'), t.tags),
                 'user_api_key_alias:', '')
    ) AS system,
    coalesce(nullIf(o.model, ''), 'unknown')  AS model,
    t.id                                      AS trace_id,
    coalesce(nullIf(o.level, ''), 'UNKNOWN')  AS status,
    o.latency_ms                              AS latency_ms,
    o.in_tok                                  AS input_tokens,
    o.out_tok                                 AS output_tokens,
    o.tot_tok                                 AS total_tokens,
    -- Hash, never store. lower(hex(SHA256(...))) is 64 chars = FixedString(64).
    lower(hex(SHA256(coalesce(t.input, ''))))  AS input_sha256,
    lower(hex(SHA256(coalesce(t.output, '')))) AS output_sha256
FROM default.traces AS t
LEFT JOIN
(
    SELECT
        trace_id,
        any(provided_model_name)                                          AS model,
        any(level)                                                        AS level,
        toUInt32(max(dateDiff('millisecond', start_time, end_time)))      AS latency_ms,
        toUInt32(sum(usage_details['input']))                             AS in_tok,
        toUInt32(sum(usage_details['output']))                            AS out_tok,
        toUInt32(sum(usage_details['total']))                             AS tot_tok
    FROM default.observations
    WHERE start_time >= now() - INTERVAL $LOOKBACK DAY
    GROUP BY trace_id
) AS o ON o.trace_id = t.id
WHERE t.timestamp >= now() - INTERVAL $LOOKBACK DAY
  AND t.is_deleted = 0
" || { echo "[ERROR] export INSERT failed" >&2; exit 1; }

# Collapse duplicate versions now rather than waiting for a background merge, so
# the counts below are honest.
ch -q "OPTIMIZE TABLE ai_governance.gateway_calls FINAL" >/dev/null 2>&1

after=$(ch -q "SELECT count() FROM ai_governance.gateway_calls" | tr -d '[:space:]')
unattr=$(ch -q "SELECT count() FROM ai_governance.gateway_calls WHERE system = 'unattributed'" | tr -d '[:space:]')
# The TOTAL unattributed count is the wrong thing to alert on: it is dominated by
# history and shrinks on its own as the 14d source TTL rolls forward, so an alert
# on it would resolve itself without anyone fixing anything. What is actionable is
# a call in the LAST 2 DAYS that we still cannot tie to a system — that means a
# live consumer is bypassing the key alias.
unattr_recent=$(ch -q "SELECT count() FROM ai_governance.gateway_calls WHERE system = 'unattributed' AND ts >= now() - INTERVAL 2 DAY" | tr -d '[:space:]')
unattr_recent=${unattr_recent:-0}
oldest=$(ch -q "SELECT ifNull(toString(min(ts)),'-') FROM ai_governance.gateway_calls" | tr -d '\n')
bytes=$(ch -q "SELECT sum(bytes_on_disk) FROM system.parts WHERE database='ai_governance' AND active" | tr -d '[:space:]')
bytes=${bytes:-0}

echo "== AI audit export =="
echo "  window        last ${LOOKBACK}d"
echo "  rows          $before -> $after (+$((after - before)))"
echo "  unattributed  $unattr total / $unattr_recent in last 2d"
echo "  oldest record $oldest"
echo "  on disk       $((bytes / 1024)) KiB"

if [ "$PUBLISH" = "1" ]; then
  if [ ! -d "$TEXTFILE_DIR" ]; then
    echo "metrics: SKIP (no $TEXTFILE_DIR)" >&2
  elif [ ! -w "$TEXTFILE_DIR" ]; then
    echo "[ERROR] metrics: $TEXTFILE_DIR NOT WRITABLE by $(id -un) — results go STALE SILENTLY" >&2
  else
    tmp="$TEXTFILE_DIR/.homelab_ai_audit.prom.$$"
    {
      echo "# HELP homelab_ai_audit_rows Rows in the long-lived AI gateway audit record."
      echo "# TYPE homelab_ai_audit_rows gauge"
      echo "homelab_ai_audit_rows $after"
      echo "# HELP homelab_ai_audit_unattributed Audit rows that cannot be tied to an inventory system."
      echo "# TYPE homelab_ai_audit_unattributed gauge"
      echo "homelab_ai_audit_unattributed $unattr"
      echo "# HELP homelab_ai_audit_unattributed_recent Unattributable calls in the last 2 days — the actionable signal."
      echo "# TYPE homelab_ai_audit_unattributed_recent gauge"
      echo "homelab_ai_audit_unattributed_recent $unattr_recent"
      echo "# HELP homelab_ai_audit_bytes On-disk size of the audit record."
      echo "# TYPE homelab_ai_audit_bytes gauge"
      echo "homelab_ai_audit_bytes $bytes"
      echo "# HELP homelab_ai_audit_last_run_timestamp_seconds Unix time of the last successful export."
      echo "# TYPE homelab_ai_audit_last_run_timestamp_seconds gauge"
      echo "homelab_ai_audit_last_run_timestamp_seconds $(date +%s)"
    } > "$tmp" && mv -f "$tmp" "$TEXTFILE_DIR/homelab_ai_audit.prom"
    echo "metrics: wrote homelab_ai_audit.prom (rows=$after unattributed_recent=$unattr_recent)"
  fi
fi
