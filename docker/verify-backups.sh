#!/usr/bin/env bash
# ============================================================================
# Weekly backup VERIFICATION — restore-side proof, not write-side hope.
#
# WHY THIS EXISTS. On 2026-07-18 three independent backup failures were found in
# one session, and the existing monitoring caught NONE of them, because every
# check ran on the WRITE side and every one of them "passed":
#   1. the metric write was failing (unwritable textfile dir) so BackupStale
#      fired for 9 days against a frozen timestamp while backups were fine;
#   2. QuestDB archived an EMPTY directory nightly for weeks — `[ -s "$out" ]`
#      passed because gzip of an empty dir is a valid ~87-byte file;
#   3. MinIO archived a 3-week-stale path after storage tiering re-pointed it.
# In all three the component reported success. The only class of check that
# would have caught all three is: OPEN THE ARCHIVE AND ASSERT ITS CONTENTS.
#
# So this script never trusts an exit code. For each component it reads the most
# recent artifact back and asserts something that is only true if real data is
# inside — expected directories, expected SQL objects, entry-count floors. And
# for the off-host copy it does a genuine RESTORE ROUND-TRIP out of restic and
# SHA256-compares against the local original: the actual DR question.
#
# Cron (installed on jarvis) — Sundays 03:00, after 02:00 backup + restic check:
#   0 3 * * 0  /opt/homelab/verify-backups.sh >> /srv/ai-data/backups/verify.log 2>&1
#
# Emits homelab_backup_verify_* to node-exporter's textfile collector; alert
# rules BackupVerifyStale / BackupVerifyFailed / BackupVerifyMetricsMissing key
# off them. See docs/off-host-backup.md.
# ============================================================================
set -uo pipefail            # NOT -e: one component failing must not skip the rest
cd "$(dirname "$0")"

BK="${BACKUP_DIR:-/srv/ai-data/backups}"
TEXTFILE_DIR="${TEXTFILE_DIR:-/var/lib/node_exporter/textfile}"
# Scratch lives OUTSIDE $BK on purpose: anything under $BK gets swept into the next
# restic run and the retention sweep. Same SSD tier, never the nvme root.
SCRATCH="${SCRATCH_DIR:-/srv/ai-data/.verify-restore}"
log(){ echo "[$(date '+%F %T')] $*"; }
val(){ grep -E "^$1=" .env | head -1 | cut -d= -f2- | sed -e "s/^['\"]//" -e "s/['\"]\$//"; }

mountpoint -q /srv/ai-data || { echo "[FATAL] /srv/ai-data not mounted — refusing to verify"; exit 1; }
rm -rf "$SCRATCH"; mkdir -p "$SCRATCH"
trap 'rm -rf "$SCRATCH"' EXIT

declare -A VERIFY_OK
check(){  # $1 = component, $2 = function
  if "$2"; then VERIFY_OK[$1]=1; log "  $1: OK"
  else VERIFY_OK[$1]=0; log "  [ERROR] $1: VERIFY FAILED"; fi
}

# Newest artifact matching a glob, or empty if none.
newest(){ ls -1t "$BK"/$1 2>/dev/null | head -1; }

# Assert a tar.gz contains at least $2 entries AND every path in $3.. is present.
# Entry-count floors are deliberate: "valid archive" and "archive with data in it"
# are different claims, and only the second one is a backup.
# NOTE ON `grep -q` AND pipefail — this bit us writing this script. `grep -q` exits at
# the FIRST match and closes the pipe, so the writer upstream dies of SIGPIPE (141); with
# `set -o pipefail` that 141 becomes the pipeline's status, so a SUCCESSFUL match reports
# FAILURE. It only shows up on inputs big enough that the writer is still writing — the
# 183k-entry MinIO listing hit it, smaller ones didn't. So: grep FILES, never pipe into
# `grep -q` here.
assert_tar(){  # $1 = file, $2 = min entries, $3.. = required path substrings
  local f="$1" min="$2"; shift 2
  [ -n "$f" ] && [ -f "$f" ] || { log "    no artifact found"; return 1; }
  local lst="$SCRATCH/listing.$$" n
  tar tzf "$f" > "$lst" 2>/dev/null || { log "    unreadable/corrupt: $(basename "$f")"; rm -f "$lst"; return 1; }
  n=$(grep -c . "$lst")
  [ "$n" -ge "$min" ] || { log "    only $n entries (need >=$min) in $(basename "$f")"; rm -f "$lst"; return 1; }
  local want
  for want in "$@"; do
    grep -q -F -- "$want" "$lst" || { log "    missing '$want' in $(basename "$f")"; rm -f "$lst"; return 1; }
  done
  rm -f "$lst"
  log "    $(basename "$f"): $n entries, all required paths present"
}

verify_postgres(){
  local f; f=$(newest 'postgres-all-*.sql.gz')
  [ -n "$f" ] || { log "    no postgres dump found"; return 1; }
  # Stream-decompress: proves the gzip is intact end-to-end without landing 335 MB.
  local dbs hdr
  dbs=$(gzip -dc "$f" 2>/dev/null | grep -c '^CREATE DATABASE ') || true
  gzip -t "$f" 2>/dev/null || { log "    gzip integrity FAILED"; return 1; }
  # A dumpall with no CREATE DATABASE is a dump of nothing — the failure mode we care about.
  [ "${dbs:-0}" -ge 5 ] || { log "    only ${dbs:-0} CREATE DATABASE stmts (need >=5)"; return 1; }
  # pg_dumpall writes "PostgreSQL database CLUSTER dump" — pg_dump's per-DB header omits
  # "cluster", so matching the pg_dump string here silently fails on a perfectly good dump.
  hdr=$(gzip -dc "$f" 2>/dev/null | head -20)
  grep -q -F 'PostgreSQL database cluster dump' <<<"$hdr" \
    || { log "    missing pg_dumpall cluster header"; return 1; }
  log "    $(basename "$f"): gzip OK, $dbs databases"
}

verify_clickhouse(){
  # NB: the artifact is named clickhouse-*.zip on disk; "ch-*.zip" is only the name
  # used INSIDE the container before `docker cp` renames it (see backup_clickhouse).
  local f; f=$(newest 'clickhouse-*.zip')
  [ -n "$f" ] || { log "    no clickhouse backup found"; return 1; }
  # ClickHouse BACKUP writes a zip; testzip() walks every CRC.
  python3 - "$f" <<'PY' || return 1
import sys, zipfile
p = sys.argv[1]
try:
    z = zipfile.ZipFile(p)
except Exception as e:
    print(f"    not a readable zip: {e}"); sys.exit(1)
bad = z.testzip()
if bad: print(f"    CRC failure on {bad}"); sys.exit(1)
n = len(z.namelist())
if n < 10: print(f"    only {n} entries (need >=10)"); sys.exit(1)
if not any(x.endswith(".sql") or "/data/" in x or "metadata" in x for x in z.namelist()):
    print("    no recognisable ClickHouse backup content"); sys.exit(1)
print(f"    {p.split('/')[-1]}: zip CRC OK, {n} entries")
PY
}

# Floors are set just under the observed real sizes (questdb 219, minio 183k, homarr 6),
# low enough not to false-alarm on normal variation but high enough that an empty or
# wrong-source archive — the actual failure seen on 2026-07-18 — can never pass.
verify_questdb(){ assert_tar "$(newest 'questdb-*.tar.gz')"   50 './db/' './conf/'; }
verify_minio(){   assert_tar "$(newest 'minio-*.tar.gz')"   1000 './mlflow/' './langfuse/'; }
verify_homarr(){  assert_tar "$(newest 'homarr-*.tar.gz')"     4 './db/db.sqlite'; }
# Fresh neo4j /data is 108 entries; the nodestore file is the definitive "this is a
# real graph store" marker (an empty/wrong-source tar can't fabricate it). Floor 50.
verify_neo4j(){   assert_tar "$(newest 'neo4j-example-*.tar.gz')" 50 './databases/neo4j/neostore.nodestore.db' './transactions/'; }

# The real DR test: pull a file back OUT of the off-host repo and prove it is
# byte-identical to the local original. `restic backup` exiting 0 says the upload
# was accepted; only a restore says the copy is usable.
verify_offhost(){
  local user pass host repopw
  user=$(val ASUSTOR_INTEGRATION_LOGIN); pass=$(val RESTIC_REST_PASSWORD)
  host=$(val ASUSTOR_HOST_NAME);         repopw=$(val RESTIC_PASSWORD)
  [ -n "$user$pass$host$repopw" ] || { log "    SKIP-FAIL (missing ASUSTOR_/RESTIC_ vars)"; return 1; }
  command -v restic >/dev/null     || { log "    SKIP-FAIL (restic not installed)"; return 1; }
  export RESTIC_REPOSITORY="rest:http://${user}:${pass}@${host}:28000/${user}/"
  export RESTIC_PASSWORD="$repopw"
  local rc=0
  # Smallest real artifact keeps the round-trip cheap while still proving the path.
  local src; src=$(newest 'homarr-*.tar.gz')
  if [ -z "$src" ]; then log "    no local artifact to compare against"; rc=1; else
    if restic restore latest --target "$SCRATCH/restore" --include "$src" >/dev/null 2>&1; then
      local restored="$SCRATCH/restore$src"
      if [ -f "$restored" ]; then
        local a b; a=$(sha256sum "$src" | cut -d' ' -f1); b=$(sha256sum "$restored" | cut -d' ' -f1)
        if [ "$a" = "$b" ]; then log "    restored $(basename "$src") from off-host, SHA256 matches local"
        else log "    RESTORED FILE DIFFERS from local original — off-host copy is corrupt"; rc=1; fi
      else log "    restore produced no file at $restored"; rc=1; fi
    else log "    restic restore FAILED"; rc=1; fi
  fi
  # Snapshot count is a cheap continuity check: the repo should be GROWING.
  local n; n=$(restic snapshots --json 2>/dev/null | python3 -c "
import json,sys
try: print(len(json.load(sys.stdin)))
except Exception: print(0)" 2>/dev/null)
  [ "${n:-0}" -ge 2 ] && log "    off-host repo holds $n snapshots" \
    || { log "    off-host repo holds only ${n:-0} snapshots"; rc=1; }
  # DELIBERATELY NOT TESTED HERE: append-only enforcement. The only real test is to
  # attempt a delete — and if the flag were off, this job would DESTROY the newest DR
  # snapshot to prove a point. An automated weekly delete attempt is a bigger risk than
  # the drift it detects. It stays a manual runbook step, done at cutover (see
  # docs/off-host-backup.md and the stor-nas-infra ADOPT-RESTIC-REST.md ask).
  unset RESTIC_REPOSITORY RESTIC_PASSWORD
  return $rc
}

START=$(date +%s)
log "===== backup verification start ====="
check postgres   verify_postgres
check clickhouse verify_clickhouse
check questdb    verify_questdb
check minio      verify_minio
check homarr     verify_homarr
check neo4j      verify_neo4j
check offhost    verify_offhost
END=$(date +%s)

# Publish to node-exporter. Same writability contract as backup.sh: a dir that
# exists but isn't writable is the dangerous case (the stale file keeps getting
# scraped, so absent() never trips) — so check -w and fail loudly, never log a
# success we did not verify.
publish(){
  [ -d "$TEXTFILE_DIR" ] || { log "metrics: SKIP (no $TEXTFILE_DIR)"; return 0; }
  [ -w "$TEXTFILE_DIR" ] || { log "[ERROR] metrics: $TEXTFILE_DIR NOT WRITABLE by $(id -un) — verify results will go STALE silently; fix: sudo chgrp homelab $TEXTFILE_DIR && sudo chmod 2775 $TEXTFILE_DIR"; return 1; }
  local tmp="$TEXTFILE_DIR/.homelab_backup_verify.prom.$$" out="$TEXTFILE_DIR/homelab_backup_verify.prom" all=1 c
  {
    echo "# HELP homelab_backup_verify_success Whether each component's newest backup passed a restore-side content check (1=ok)."
    echo "# TYPE homelab_backup_verify_success gauge"
    for c in "${!VERIFY_OK[@]}"; do
      echo "homelab_backup_verify_success{component=\"$c\"} ${VERIFY_OK[$c]}"
      [ "${VERIFY_OK[$c]}" = 1 ] || all=0
    done
    echo "# HELP homelab_backup_verify_last_run_timestamp_seconds Unix time the last verification finished."
    echo "# TYPE homelab_backup_verify_last_run_timestamp_seconds gauge"
    echo "homelab_backup_verify_last_run_timestamp_seconds $END"
    echo "# HELP homelab_backup_verify_duration_seconds Wall-clock duration of the last verification."
    echo "# TYPE homelab_backup_verify_duration_seconds gauge"
    echo "homelab_backup_verify_duration_seconds $((END - START))"
    echo "# HELP homelab_backup_verify_last_success_timestamp_seconds Unix time of the last run where EVERY component verified."
    echo "# TYPE homelab_backup_verify_last_success_timestamp_seconds gauge"
    if [ "$all" = 1 ]; then
      echo "homelab_backup_verify_last_success_timestamp_seconds $END"
    else
      local prev
      prev=$(grep -h '^homelab_backup_verify_last_success_timestamp_seconds ' "$out" 2>/dev/null | awk '{print $2}' | tail -1)
      echo "homelab_backup_verify_last_success_timestamp_seconds ${prev:-0}"
    fi
  } > "$tmp" && mv -f "$tmp" "$out" && chmod 644 "$out" || {
    rm -f "$tmp" 2>/dev/null
    log "[ERROR] metrics: FAILED to write $out — verification results will look stale to Prometheus"
    return 1
  }
  log "metrics: wrote $out (all_ok=$all)"
}
publish

FAILED=0
for c in "${!VERIFY_OK[@]}"; do [ "${VERIFY_OK[$c]}" = 1 ] || FAILED=$((FAILED+1)); done
log "===== verification done in $((END - START))s — ${#VERIFY_OK[@]} components, $FAILED failed ====="
exit 0
