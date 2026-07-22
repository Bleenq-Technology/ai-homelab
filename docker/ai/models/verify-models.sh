#!/usr/bin/env bash
# ============================================================================
# Verify model-weight integrity + provenance (todos.md #45).
#
# WHY: we pin image versions rigorously — "no :latest" is a stated quality bar —
# and until 2026-07-22 pinned our model weights not at all. No hash, no source
# URL, no revision, no licence for any GGUF on the box. A silently swapped,
# truncated, or corrupted weights file was undetectable. For bge-m3 that matters
# more than it looks: every kb_* collection is embedded with it, so a changed
# file silently invalidates the entire KB library.
#
# TWO DIRECTIONS, and the second is the one that finds things:
#   1. Every model in manifest.json still hashes to its recorded sha256.
#   2. Every .gguf ON THE HOST appears in manifest.json — this is what caught
#      6.9 GB of unregistered gemma-4 weights nobody remembered downloading.
#
# Mirrors verify-backups.sh deliberately: restore-side verification, run weekly,
# alerting through the existing Alertmanager -> Discord path. Hashing several GB
# takes a few minutes — that is why this is weekly and not on every deploy.
#
# Usage:  ./verify-models.sh [--publish]
# ============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
MANIFEST="${MANIFEST:-$HERE/manifest.json}"
TEXTFILE_DIR="${TEXTFILE_DIR:-/var/lib/node_exporter/textfile}"
PUBLISH=0
[ "${1:-}" = "--publish" ] && PUBLISH=1

command -v jq >/dev/null 2>&1 || { echo "jq required" >&2; exit 2; }
[ -f "$MANIFEST" ] || { echo "no manifest at $MANIFEST" >&2; exit 2; }

ok=0; failed=0; skipped=0; unregistered=0

echo "== model weight verification =="
echo

# ---- 1. manifest -> disk ---------------------------------------------------
while IFS=$'\t' read -r name path want status; do
  if [ "$want" = "null" ] || [ -z "$want" ]; then
    echo "  SKIP   $name — no sha256 recorded (status=$status)"
    skipped=$((skipped + 1))
    continue
  fi
  if [ ! -f "$path" ]; then
    echo "  FAIL   $name — MISSING at $path"
    failed=$((failed + 1))
    continue
  fi
  got=$(sudo sha256sum "$path" 2>/dev/null | cut -d' ' -f1)
  if [ "$got" = "$want" ]; then
    echo "  ok     $name"
    ok=$((ok + 1))
  else
    # The dangerous case: the file is present and the service starts fine, but
    # it is NOT the artifact we recorded.
    echo "  FAIL   $name — HASH MISMATCH"
    echo "           expected $want"
    echo "           actual   $got"
    failed=$((failed + 1))
  fi
done < <(jq -r '.models[] | [.name, .path, (.sha256 // "null"), .status] | @tsv' "$MANIFEST")

# ---- 2. disk -> manifest (the reverse check) -------------------------------
echo
echo "-- unregistered weights on the host --"
mapfile -t SCAN < <(jq -r '.scan_paths[]' "$MANIFEST")
mapfile -t IGNORE < <(jq -r '.ignore_globs[]?' "$MANIFEST")

for root in "${SCAN[@]}"; do
  [ -d "$root" ] || continue
  while IFS= read -r f; do
    skip=0
    for g in "${IGNORE[@]}"; do
      # shellcheck disable=SC2053
      [[ "$f" == $g ]] && { skip=1; break; }
    done
    [ "$skip" = 1 ] && continue
    # A file counts as registered if its path matches a manifest entry, or sits
    # under a manifest entry's directory (HF caches are directories of blobs).
    #
    # GOTCHA: bind .path to $p FIRST. Writing `$f | startswith(.path + "/")`
    # pipes into the STRING $f, so `.path` is then evaluated against a string and
    # jq errors "Cannot index string with string". The error exit made `if !`
    # read as "unregistered", so every entry after a short-circuit was reported
    # as a false positive.
    if ! jq -e --arg f "$f" \
        '.models[] | select(.path as $p | ($f == $p) or ($f | startswith($p + "/")))' \
        "$MANIFEST" >/dev/null 2>&1; then
      sz=$(sudo du -h "$f" 2>/dev/null | cut -f1)
      echo "  UNREGISTERED  $f  ($sz)"
      unregistered=$((unregistered + 1))
    fi
  done < <(sudo find "$root" -name "*.gguf" -size +10M 2>/dev/null)
done
[ "$unregistered" -eq 0 ] && echo "  (none — every weights file on the host is in the manifest)"

echo
echo "== $ok ok · $failed failed · $skipped skipped · $unregistered unregistered =="

if [ "$PUBLISH" = "1" ]; then
  if [ ! -d "$TEXTFILE_DIR" ]; then
    echo "metrics: SKIP (no $TEXTFILE_DIR)" >&2
  elif [ ! -w "$TEXTFILE_DIR" ]; then
    # Present-but-unwritable is the dangerous case — absent() never fires
    # because the stale file is still scraped (todos.md #11).
    echo "[ERROR] metrics: $TEXTFILE_DIR NOT WRITABLE by $(id -un) — results will go STALE SILENTLY" >&2
  else
    tmp="$TEXTFILE_DIR/.homelab_ai_models.prom.$$"
    {
      echo "# HELP homelab_ai_model_verify_success 1 if every manifest-recorded weight matched its hash."
      echo "# TYPE homelab_ai_model_verify_success gauge"
      echo "homelab_ai_model_verify_success $([ "$failed" -eq 0 ] && echo 1 || echo 0)"
      echo "# HELP homelab_ai_model_verify_failures Weights missing or hash-mismatched."
      echo "# TYPE homelab_ai_model_verify_failures gauge"
      echo "homelab_ai_model_verify_failures $failed"
      echo "# HELP homelab_ai_model_unregistered Weights files on the host with no manifest entry."
      echo "# TYPE homelab_ai_model_unregistered gauge"
      echo "homelab_ai_model_unregistered $unregistered"
      echo "# HELP homelab_ai_model_verify_last_run_timestamp_seconds Unix time of the last verification."
      echo "# TYPE homelab_ai_model_verify_last_run_timestamp_seconds gauge"
      echo "homelab_ai_model_verify_last_run_timestamp_seconds $(date +%s)"
    } > "$tmp" && mv -f "$tmp" "$TEXTFILE_DIR/homelab_ai_models.prom"
    echo "metrics: wrote homelab_ai_models.prom (failed=$failed unregistered=$unregistered)"
  fi
fi

[ "$failed" -gt 0 ] && exit 1
exit 0
