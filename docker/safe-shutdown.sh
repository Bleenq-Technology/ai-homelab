#!/usr/bin/env bash
# ============================================================================
# safe-shutdown.sh — clean, verified power-off / restart of jarvis.
#
# Order matters:
#   1. confirm (type "yes")
#   2. ensure a RECENT full backup exists (else run backup.sh) — MUST happen while
#      the stack is UP, since backup.sh does pg_dumpall / CH BACKUP / etc. via
#      `docker exec` on running containers. A backup reporting [ERROR] blocks the
#      shutdown unless --force (the whole point is "don't power off unprotected").
#   3. gracefully stop the docker stack (SIGTERM, generous timeout) so the DBs flush
#   4. minimize swap (swapoff/swapon) — only now, with the stack stopped and RAM
#      freed, is it safe to pull swap back into RAM
#   5. sync + verify dirty pages are flushed
#   6. poweroff / reboot
#
# NOTE: services use `restart: unless-stopped`, so once this script stops them they
# stay down across a reboot. After the host comes back, bring the stack up with:
#     cd /opt/homelab && docker compose -f compose.yml up -d
#
# Usage:
#   ./safe-shutdown.sh                 # interactive: pick shutdown/restart, confirm
#   ./safe-shutdown.sh --poweroff -y   # non-interactive power off (skip the yes prompt)
#   ./safe-shutdown.sh --reboot        # restart
#   ./safe-shutdown.sh --dry-run       # show every step, change nothing
#   --force            proceed even if the backup reported errors
#   --max-age-min N    backup considered fresh if newer than N minutes (default 360 = 6h)
#   --stop-timeout N   graceful per-container stop timeout in seconds (default 60)
# ============================================================================
set -uo pipefail
cd "$(dirname "$0")" || exit 1            # -> /opt/homelab

BK="$(pwd)/backups"
LOG="$BK/backup.log"
COMPOSE="compose.yml"
MAX_AGE_MIN="${BACKUP_MAX_AGE_MIN:-360}"  # 6h
STOP_TIMEOUT="${STOP_TIMEOUT:-60}"
ACTION=""; ASSUME_YES=0; DRY_RUN=0; FORCE=0

die(){ echo "ERROR: $*" >&2; exit 1; }
say(){ echo "[$(date '+%H:%M:%S')] $*"; }
kib_mib(){ awk -v k="$1" 'BEGIN{printf "%.0f", k/1024}'; }   # KiB -> MiB

usage(){ sed -n '2,/^# ===.*$/{/^# ===/d;s/^# \{0,1\}//;p}' "$0"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --poweroff|--shutdown|--off) ACTION=poweroff ;;
    --reboot|--restart)          ACTION=reboot ;;
    -y|--yes)                    ASSUME_YES=1 ;;
    -n|--dry-run)                DRY_RUN=1 ;;
    --force)                     FORCE=1 ;;
    --max-age-min)               shift; MAX_AGE_MIN="${1:?}" ;;
    --stop-timeout)              shift; STOP_TIMEOUT="${1:?}" ;;
    -h|--help)                   usage; exit 0 ;;
    *) die "unknown argument: $1 (try --help)" ;;
  esac
  shift
done

# --- sanity: are we actually on the homelab host? -------------------------------
[ -f "$COMPOSE" ] || die "no $COMPOSE in $(pwd) — run this from /opt/homelab on jarvis."
command -v docker >/dev/null || die "docker not found."

# --- choose action --------------------------------------------------------------
if [ -z "$ACTION" ]; then
  if [ -t 0 ]; then
    read -r -p 'Shut down or restart? [s/r]: ' a
    case "$a" in s|S|shutdown) ACTION=poweroff ;; r|R|restart|reboot) ACTION=reboot ;;
      *) die "expected s or r." ;; esac
  else
    die "no action given and not a TTY — pass --poweroff or --reboot."
  fi
fi
verb=$([ "$ACTION" = reboot ] && echo restart || echo "shut down")

echo
say "Plan: ${verb} jarvis."
say "  - ensure a full backup within ${MAX_AGE_MIN} min (run backup.sh if stale)"
say "  - graceful stop of the docker stack (-t ${STOP_TIMEOUT}s)"
say "  - minimize swap, sync, verify, then ${ACTION}"
[ "$DRY_RUN" = 1 ] && say "  (DRY-RUN: nothing will actually be stopped or powered off)"
echo

# --- confirm --------------------------------------------------------------------
if [ "$ASSUME_YES" != 1 ]; then
  read -r -p "Type \"yes\" if you really want to ${verb}: " ans
  [ "$ans" = yes ] || die "not confirmed — aborting."
fi

# --- 1. backup freshness --------------------------------------------------------
newest=$(ls -t "$BK"/postgres-all-*.sql.gz 2>/dev/null | head -1 || true)
run_out=""
if [ -n "$newest" ] && [ -n "$(find "$newest" -mmin "-${MAX_AGE_MIN}" 2>/dev/null)" ]; then
  age_min=$(( ( $(date +%s) - $(stat -c %Y "$newest") ) / 60 ))
  say "backup: fresh — $(basename "$newest") (${age_min} min old, < ${MAX_AGE_MIN})"
  # pull the last run's section out of the log to surface any [ERROR]s
  run_out=$(awk '/===== homelab backup .* start =====/{buf=""} {buf=buf $0 ORS} END{printf "%s", buf}' "$LOG" 2>/dev/null)
else
  say "backup: stale or missing — running ./backup.sh now (stack still up)…"
  if [ "$DRY_RUN" = 1 ]; then
    say "  DRY-RUN: would run ./backup.sh"
  else
    [ -x ./backup.sh ] || die "./backup.sh not found/executable."
    tmp=$(mktemp)
    ./backup.sh 2>&1 | tee -a "$LOG" | tee "$tmp"
    run_out=$(cat "$tmp"); rm -f "$tmp"
  fi
fi

errs=$(printf '%s' "$run_out" | grep -F '[ERROR]' || true)
if [ -n "$errs" ]; then
  echo; say "WARNING — the backup reported errors:"; printf '%s\n' "$errs"; echo
  if [ "$FORCE" != 1 ] && [ "$DRY_RUN" != 1 ]; then
    if [ "$ASSUME_YES" = 1 ]; then
      die "backup had errors and --force not given — refusing to ${verb}."
    fi
    read -r -p "Backup had errors. ${verb} ANYWAY? Type \"yes\": " ans2
    [ "$ans2" = yes ] || die "aborting due to backup errors (good call)."
  fi
else
  say "backup: no [ERROR] markers in the latest run ✓"
fi

# --- 2. stop the docker stack (graceful) ---------------------------------------
say "stopping docker stack: docker compose -f ${COMPOSE} stop -t ${STOP_TIMEOUT}"
if [ "$DRY_RUN" = 1 ]; then
  say "  DRY-RUN: would stop $(docker compose -f "$COMPOSE" ps --services 2>/dev/null | wc -l) services"
else
  docker compose -f "$COMPOSE" stop -t "$STOP_TIMEOUT" || say "WARN: compose stop returned non-zero (continuing)"
fi

# --- 3. minimize swap (only now that RAM is freed) ------------------------------
read -r swap_total swap_free mem_avail < <(awk '
  /^SwapTotal:/{st=$2} /^SwapFree:/{sf=$2} /^MemAvailable:/{ma=$2}
  END{print st, sf, ma}' /proc/meminfo)
swap_used=$(( swap_total - swap_free ))
if [ "$swap_used" -le 0 ]; then
  say "swap: nothing in use (skip)"
else
  need=$(( swap_used * 12 / 10 ))   # 20% headroom
  say "swap: $(kib_mib "$swap_used") MiB in use; $(kib_mib "$mem_avail") MiB RAM available"
  if [ "$mem_avail" -gt "$need" ]; then
    say "swap: clearing (swapoff -a && swapon -a)"
    [ "$DRY_RUN" = 1 ] && say "  DRY-RUN: would swapoff/swapon" || \
      { sudo swapoff -a && sudo swapon -a && say "swap: cleared ✓"; } || say "WARN: swap clear failed (continuing)"
  else
    say "swap: SKIP clearing — not enough free RAM to hold it safely"
  fi
fi

# --- 4. flush + verify ----------------------------------------------------------
say "flushing filesystems (sync)…"
[ "$DRY_RUN" = 1 ] || { sync; sync; }
read -r dirty wb < <(awk '/^Dirty:/{d=$2} /^Writeback:/{w=$2} END{print d, w}' /proc/meminfo)
say "dirty+writeback after sync: $((dirty + wb)) KiB"
if [ "$DRY_RUN" != 1 ] && [ $((dirty + wb)) -gt 16384 ]; then
  say "still >16 MiB unflushed — syncing again…"; sync; sleep 1; sync
fi

# --- 5. go ----------------------------------------------------------------------
echo
if [ "$DRY_RUN" = 1 ]; then
  say "DRY-RUN complete — would now: sudo systemctl ${ACTION}"
  exit 0
fi
say "All clear. Issuing '${ACTION}' in 5s — Ctrl-C to abort."
sleep 5
exec sudo systemctl "$ACTION"
