#!/usr/bin/env bash
# ============================================================================
# Nightly homelab backup.
#   * pg_dumpall — ALL Postgres databases + roles (Keycloak, NetBox, Infisical's
#     encrypted secret store, Baserow, Langfuse metadata, Firezone) in one file.
#   * gzip -> ./backups/ (rotated, RETAIN_DAYS) and copied to MinIO bucket "backups".
#
# Cron (installed on jarvis):
#   0 2 * * *  /opt/homelab/backup.sh >> /opt/homelab/backups/backup.log 2>&1
#
# NOT yet covered (documented next steps): ClickHouse (Langfuse traces), MinIO
# object data, and OFF-HOST replication (local+MinIO both live on jarvis's disk).
# ============================================================================
set -euo pipefail
cd "$(dirname "$0")"
BK="$(pwd)/backups"; mkdir -p "$BK"
TS=$(date +%Y%m%d-%H%M%S)
RETAIN_DAYS="${RETAIN_DAYS:-7}"
MC_IMAGE="minio/mc:RELEASE.2025-04-03T17-07-56Z"

# Infisical exports .env values single-quoted; strip surrounding quotes.
val(){ grep -E "^$1=" .env | head -1 | cut -d= -f2- | sed -e "s/^['\"]//" -e "s/['\"]\$//"; }
PGUSER=$(val POSTGRES_SUPERUSER); PGPW=$(val POSTGRES_PASSWORD)
MUSER=$(val MINIO_ROOT_USER);     MPW=$(val MINIO_ROOT_PASSWORD)

OUT="$BK/postgres-all-$TS.sql.gz"
echo "[$(date '+%F %T')] dumping all Postgres databases -> $(basename "$OUT")"
docker exec -e PGPASSWORD="$PGPW" postgres pg_dumpall -U "$PGUSER" | gzip > "$OUT"
echo "[$(date '+%F %T')] wrote $(du -h "$OUT" | cut -f1)"

echo "[$(date '+%F %T')] copying to MinIO bucket 'backups'"
docker run --rm --network data --entrypoint sh -v "$BK:/bk" "$MC_IMAGE" -c "
  mc alias set m http://minio:9000 '$MUSER' '$MPW' >/dev/null &&
  mc mb --ignore-existing m/backups >/dev/null &&
  mc cp /bk/$(basename "$OUT") m/backups/ >/dev/null" \
  && echo "[$(date '+%F %T')] uploaded to m/backups/"

# prune local copies older than RETAIN_DAYS
find "$BK" -name 'postgres-all-*.sql.gz' -mtime +"$RETAIN_DAYS" -delete
echo "[$(date '+%F %T')] done; local backups: $(ls "$BK"/postgres-all-*.sql.gz 2>/dev/null | wc -l)"
