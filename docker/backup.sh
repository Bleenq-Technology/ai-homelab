#!/usr/bin/env bash
# ============================================================================
# Nightly homelab backup — ALL stateful datastores.
#   * Postgres   — pg_dumpall (Keycloak, NetBox, Infisical store, Baserow,
#                  Langfuse metadata, MLflow, n8n, ...) -> .sql.gz
#   * ClickHouse — native online `BACKUP ALL EXCEPT ...` (Langfuse traces) -> .zip
#   * QuestDB    — CHECKPOINT CREATE + tar of the data volume -> .tar.gz
#   * MinIO      — tar of the object store (MLflow artifacts, Langfuse, ...) -> .tar.gz
#   * Homarr     — tar of the appdata SQLite dir (dashboard config) -> .tar.gz
#
# Each logical dump (PG/CH/QuestDB/Homarr) is also copied to the MinIO "backups"
# bucket. Local copies rotate after RETAIN_DAYS. Backups are crash-consistent (CH
# BACKUP and QuestDB CHECKPOINT are online-consistent; MinIO objects are immutable).
#
# Cron (installed on jarvis):
#   0 2 * * *  /opt/homelab/backup.sh >> /srv/ai-data/backups/backup.log 2>&1
#
# OFF-HOST replica: after the local/MinIO copies, the whole backups dir is pushed
# to the Asustor NAS (stor.lab.example) via restic to an append-only REST
# server — client-side encrypted, deduplicated, integrity-checked. This is the true
# DR copy (survives loss of jarvis's disk). The NAS account can ADD but never DELETE
# (append-only), so a compromised jarvis can't wipe history. See docs/off-host-backup.md.
# ============================================================================
set -uo pipefail            # NOT -e: one datastore failing must not skip the others
cd "$(dirname "$0")"
# Backups land on the 870 EVO SSD (heavy-write tier — see docs/storage-tiering-plan.md).
# This is the single largest nightly write on the box; keeping it off the nvme root is
# the whole point of the tiering. Fail LOUD if the SSD isn't mounted rather than
# silently refilling the nvme (same guard-rail as the redpanda bind).
BK="${BACKUP_DIR:-/srv/ai-data/backups}"
mountpoint -q /srv/ai-data || { echo "[FATAL] /srv/ai-data is not mounted — refusing to write backups to the nvme root"; exit 1; }
mkdir -p "$BK"
TS=$(date +%Y%m%d-%H%M%S)
RETAIN_DAYS="${RETAIN_DAYS:-7}"
MC_IMAGE="minio/mc:RELEASE.2025-04-03T17-07-56Z"
QDB_VOLUME="homelab_questdb_data"
MINIO_DATA="/opt/homelab/data/minio/data"
# Databases excluded from the nightly ClickHouse backup:
#   system/information_schema — ClickHouse's own telemetry. Was ~97% of the dump
#     (trace_log alone was 2.9 GiB); worthless to restore. Excluding it took the
#     nightly zip from 3.3 G -> 71 M.
#   scanner — example-scanner' research store. Large (tape backfill: tens of GB)
#     and reproducible: bars_1m/trades reload idempotently (ReplacingMergeTree)
#     from the market-data source. Backing it up nightly would push tens of GB
#     into MinIO and off-host restic every night. See docker/data/clickhouse/README.md
#     for the on-demand `BACKUP DATABASE scanner` command + re-backfill runbook.
CH_EXCLUDE_DBS="system, information_schema, scanner"

log(){ echo "[$(date '+%F %T')] $*"; }
# Infisical exports .env values single-quoted; strip surrounding quotes.
val(){ grep -E "^$1=" .env | head -1 | cut -d= -f2- | sed -e "s/^['\"]//" -e "s/['\"]\$//"; }
PGUSER=$(val POSTGRES_SUPERUSER); PGPW=$(val POSTGRES_PASSWORD)
MUSER=$(val MINIO_ROOT_USER);     MPW=$(val MINIO_ROOT_PASSWORD)

# Copy a local backup file into the MinIO "backups" bucket (second on-disk copy).
push_minio(){  # $1 = local file path
  local f; f=$(basename "$1")
  docker run --rm --network data --entrypoint sh -v "$BK:/bk" "$MC_IMAGE" -c "
    mc alias set m http://minio:9000 '$MUSER' '$MPW' >/dev/null &&
    mc mb --ignore-existing m/backups >/dev/null &&
    mc cp /bk/$f m/backups/ >/dev/null" || return 1
}

backup_postgres(){
  local out="$BK/postgres-all-$TS.sql.gz"
  log "postgres: pg_dumpall -> $(basename "$out")"
  docker exec -e PGPASSWORD="$PGPW" postgres pg_dumpall -U "$PGUSER" | gzip > "$out" || return 1
  [ -s "$out" ] || return 1
  log "postgres: wrote $(du -h "$out" | cut -f1)"
  push_minio "$out" && log "postgres: -> MinIO" || log "postgres: WARN MinIO upload failed"
}

backup_clickhouse(){
  local name="ch-$TS.zip" out="$BK/clickhouse-$TS.zip"
  log "clickhouse: BACKUP ALL EXCEPT DATABASES $CH_EXCLUDE_DBS -> $name"
  docker exec clickhouse clickhouse-client --query \
    "BACKUP ALL EXCEPT DATABASES $CH_EXCLUDE_DBS TO File('$name')" >/dev/null || return 1
  docker cp "clickhouse:/var/lib/clickhouse/backups/$name" "$out" || return 1
  docker exec clickhouse rm -f "/var/lib/clickhouse/backups/$name" 2>/dev/null || true
  [ -s "$out" ] || return 1
  log "clickhouse: wrote $(du -h "$out" | cut -f1)"
  push_minio "$out" && log "clickhouse: -> MinIO" || log "clickhouse: WARN MinIO upload failed"
}

backup_questdb(){
  local out="$BK/questdb-$TS.tar.gz" qexec="http://localhost:9000/exec"
  log "questdb: CHECKPOINT CREATE"
  docker exec questdb curl -sf -G "$qexec" --data-urlencode "query=CHECKPOINT CREATE" >/dev/null || return 1
  # Tar the data volume while the checkpoint is held (consistent snapshot).
  docker run --rm -v "$QDB_VOLUME:/data:ro" alpine tar czf - -C /data . > "$out" 2>/dev/null
  local rc=$?
  docker exec questdb curl -sf -G "$qexec" --data-urlencode "query=CHECKPOINT RELEASE" >/dev/null \
    && log "questdb: CHECKPOINT RELEASE" || log "questdb: WARN CHECKPOINT RELEASE failed"
  [ $rc -eq 0 ] && [ -s "$out" ] || return 1
  log "questdb: wrote $(du -h "$out" | cut -f1)"
  push_minio "$out" && log "questdb: -> MinIO" || log "questdb: WARN MinIO upload failed"
}

backup_minio(){
  # Tar the whole object store. NOT pushed back into MinIO (circular / same disk).
  local out="$BK/minio-$TS.tar.gz"
  log "minio: tar object store -> $(basename "$out") (local only — see OFF-HOST note)"
  # Exclude the 'backups' bucket: it holds the PG/CH/QuestDB dumps we just uploaded
  # (already captured as their own files) — including it would be circular and bloat the tar.
  docker run --rm -v "$MINIO_DATA:/data:ro" alpine tar czf - -C /data --exclude='./backups' . > "$out" 2>/dev/null || return 1
  [ -s "$out" ] || return 1
  log "minio: wrote $(du -h "$out" | cut -f1)"
}

backup_homarr(){
  # Homarr keeps its whole config (boards, tiles, integrations + their encrypted
  # secrets) in a SQLite DB under the bind-mounted appdata dir — NOT in Postgres,
  # so the pg_dumpall above doesn't capture it. Tar it so the dashboard survives a
  # host/disk loss. Stopping isn't required (better-sqlite3 WAL is crash-consistent),
  # but a tar of a quiescent dir is plenty for a low-write config DB.
  local out="$BK/homarr-$TS.tar.gz" src="/opt/homelab/core/homarr/appdata"
  [ -d "$src" ] || { log "homarr: SKIP (no appdata dir at $src)"; return 1; }
  log "homarr: tar appdata -> $(basename "$out")"
  tar czf "$out" -C "$src" . 2>/dev/null || return 1
  [ -s "$out" ] || return 1
  log "homarr: wrote $(du -h "$out" | cut -f1)"
  push_minio "$out" && log "homarr: -> MinIO" || log "homarr: WARN MinIO upload failed"
}

# Off-host: encrypted + deduped replica of the whole backups dir to the Asustor NAS
# via the restic REST server (append-only). Repo + REST creds come from .env
# (Infisical: ASUSTOR_* / RESTIC_*). See docs/off-host-backup.md.
backup_offhost(){
  local user pass host repopw
  user=$(val ASUSTOR_INTEGRATION_LOGIN); pass=$(val RESTIC_REST_PASSWORD)
  host=$(val ASUSTOR_HOST_NAME);         repopw=$(val RESTIC_PASSWORD)
  [ -n "$user$pass$host$repopw" ] || { log "offhost: SKIP (missing ASUSTOR_/RESTIC_ vars)"; return 1; }
  command -v restic >/dev/null     || { log "offhost: SKIP (restic not installed)"; return 1; }
  # RESTIC_REST_PASSWORD is URL-safe hex; restic masks the URL password as *** in output.
  export RESTIC_REPOSITORY="rest:http://${user}:${pass}@${host}:28000/${user}/"
  export RESTIC_PASSWORD="$repopw"
  log "offhost: restic backup -> ${host} (append-only)"
  restic backup "$BK" --tag offhost --host jarvis || { unset RESTIC_REPOSITORY RESTIC_PASSWORD; return 1; }
  # Sundays: verify off-host repo integrity (append-only blocks prune; see runbook).
  [ "$(date +%u)" = 7 ] && { log "offhost: weekly restic check"; restic check || log "offhost: WARN check failed"; }
  unset RESTIC_REPOSITORY RESTIC_PASSWORD
}

# Publish results to Prometheus via node-exporter's textfile collector. Without this a
# backup that never RAN (host powered off at 02:00 — happened 2026-07-04) looks exactly
# like one that ran fine: the only evidence is an absent file nobody is watching. The
# `BackupStale` alert keys off last_success_timestamp; `absent()` covers "never wrote".
# Written atomically (write + mv) so a scrape never reads a half-file.
TEXTFILE_DIR="${TEXTFILE_DIR:-/var/lib/node_exporter/textfile}"
declare -A COMPONENT_OK
run_component(){  # $1 = name, $2 = function
  if "$2"; then COMPONENT_OK[$1]=1; else COMPONENT_OK[$1]=0; log "[ERROR] $1 backup FAILED"; fi
}
publish_metrics(){
  [ -d "$TEXTFILE_DIR" ] || { log "metrics: SKIP (no $TEXTFILE_DIR)"; return 0; }
  local tmp="$TEXTFILE_DIR/.homelab_backup.prom.$$" out="$TEXTFILE_DIR/homelab_backup.prom" all=1
  {
    echo "# HELP homelab_backup_component_success Whether each datastore's backup succeeded on the last run (1=ok)."
    echo "# TYPE homelab_backup_component_success gauge"
    for c in "${!COMPONENT_OK[@]}"; do
      echo "homelab_backup_component_success{component=\"$c\"} ${COMPONENT_OK[$c]}"
      [ "${COMPONENT_OK[$c]}" = 1 ] || all=0
    done
    echo "# HELP homelab_backup_last_run_timestamp_seconds Unix time the last backup run finished."
    echo "# TYPE homelab_backup_last_run_timestamp_seconds gauge"
    echo "homelab_backup_last_run_timestamp_seconds $END_EPOCH"
    echo "# HELP homelab_backup_duration_seconds Wall-clock duration of the last backup run."
    echo "# TYPE homelab_backup_duration_seconds gauge"
    echo "homelab_backup_duration_seconds $((END_EPOCH - START_EPOCH))"
    echo "# HELP homelab_backup_last_success_timestamp_seconds Unix time of the last run where EVERY component succeeded."
    echo "# TYPE homelab_backup_last_success_timestamp_seconds gauge"
    if [ "$all" = 1 ]; then
      echo "homelab_backup_last_success_timestamp_seconds $END_EPOCH"
    else
      # Preserve the previous success time — a failed run must not reset the clock.
      local prev
      prev=$(grep -h '^homelab_backup_last_success_timestamp_seconds ' "$out" 2>/dev/null | awk '{print $2}' | tail -1)
      echo "homelab_backup_last_success_timestamp_seconds ${prev:-0}"
    fi
  } > "$tmp" && mv -f "$tmp" "$out" && chmod 644 "$out"
  log "metrics: wrote $out (all_ok=$all)"
}

START_EPOCH=$(date +%s)
log "===== homelab backup $TS start ====="
run_component postgres   backup_postgres
run_component clickhouse backup_clickhouse
run_component questdb    backup_questdb
run_component minio      backup_minio
run_component homarr     backup_homarr
run_component offhost    backup_offhost
END_EPOCH=$(date +%s)
publish_metrics

# prune local copies older than RETAIN_DAYS
find "$BK" -type f \( -name 'postgres-all-*.sql.gz' -o -name 'clickhouse-*.zip' \
  -o -name 'questdb-*.tar.gz' -o -name 'minio-*.tar.gz' -o -name 'homarr-*.tar.gz' \) -mtime +"$RETAIN_DAYS" -delete
# prune the MinIO "backups" bucket too — the find above only touches local disk, so
# without this the bucket grows unbounded.
docker run --rm --network data --entrypoint sh "$MC_IMAGE" -c "
  mc alias set m http://minio:9000 '$MUSER' '$MPW' >/dev/null &&
  mc rm --recursive --force --older-than ${RETAIN_DAYS}d m/backups/ >/dev/null 2>&1" || true
log "===== backup done — sets present: pg=$(ls "$BK"/postgres-all-*.sql.gz 2>/dev/null | wc -l) ch=$(ls "$BK"/clickhouse-*.zip 2>/dev/null | wc -l) qdb=$(ls "$BK"/questdb-*.tar.gz 2>/dev/null | wc -l) minio=$(ls "$BK"/minio-*.tar.gz 2>/dev/null | wc -l) homarr=$(ls "$BK"/homarr-*.tar.gz 2>/dev/null | wc -l) ====="
