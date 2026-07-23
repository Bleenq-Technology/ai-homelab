#!/usr/bin/env bash
# ============================================================================
# Post-maintenance-reboot verification for jarvis. Proves the stack actually
# came back — not just that Docker started — and reports to Discord.
#
# Runs ONLY after a maintenance reboot (gated on the marker jarvis-apply-updates.sh
# drops), so normal reboots don't generate noise.
#
# It checks the things whose silent failure would matter most:
#   1. every container that was running before is running again (by NAME, not
#      just a count — a count can match while the wrong thing is down)
#   2. the GPU (a kernel upgrade with mismatched nvidia modules kills bge-m3 +
#      ComfyUI; the embedding model is the KB interoperability standard)
#   3. the LLM gateway actually serves (embeddings round-trip, not just a port)
#   4. the public chat surface answers
#   5. the governance eval suite is green
#
# "It booted" is not the bar — proving the restore side is (same discipline as
# verify-backups.sh).
# ============================================================================
set -uo pipefail

STATE=/var/lib/jarvis-maint
MARKER="$STATE/verify-after-boot"
[ -f "$MARKER" ] || exit 0          # not a maintenance reboot — stay quiet

LOG=/srv/ai-data/backups/maintenance.log
ENV_FILE=/opt/homelab/.env
exec >>"$LOG" 2>&1
echo "===== $(date -Is) post-boot verification (kernel $(uname -r)) ====="

notify() {
  local url payload
  url=$(grep -E '^DISCORD_WEBHOOK_URL=' "$ENV_FILE" 2>/dev/null | head -1 | cut -d= -f2-)
  [ -n "${url:-}" ] || return 0
  payload=$(python3 -c 'import json,sys; print(json.dumps({"content": sys.argv[1]}))' "$1")
  curl -sf -m 20 -H 'Content-Type: application/json' -d "$payload" "$url" >/dev/null || true
}

# ---- wait for docker, then let restart:unless-stopped containers settle -----
for _ in $(seq 1 60); do docker info >/dev/null 2>&1 && break; sleep 5; done
sleep 90

FAILS=()

# 1. containers back, by name
NOW_LIST=$(docker ps --format '{{.Names}}' 2>/dev/null | sort)
PRE=$(cat "$STATE/pre-reboot-count.txt" 2>/dev/null || echo 0)
NOW=$(printf '%s\n' "$NOW_LIST" | grep -c . || echo 0)
MISSING=$(comm -23 "$STATE/pre-reboot-containers.txt" <(printf '%s\n' "$NOW_LIST") 2>/dev/null | tr '\n' ' ')
if [ -n "${MISSING// /}" ]; then
  FAILS+=("containers ${NOW}/${PRE} — NOT back: ${MISSING}")
else
  echo "containers: ${NOW}/${PRE} all back"
fi

# 2. GPU (kernel/module mismatch is the classic post-upgrade killer)
if nvidia-smi -L >/dev/null 2>&1; then
  echo "gpu: $(nvidia-smi --query-gpu=name,driver_version --format=csv,noheader 2>/dev/null)"
else
  FAILS+=("nvidia-smi failed — GPU driver/kernel module mismatch (bge-m3 + ComfyUI affected)")
fi

# 3. LLM gateway actually serves (embeddings = the KB standard)
K=$(grep -E '^EVALS_LLM_KEY=' "$ENV_FILE" 2>/dev/null | head -1 | cut -d= -f2-)
if [ -n "${K:-}" ]; then
  CODE=$(docker run --rm --network ai curlimages/curl:8.11.1 -s -o /dev/null -w '%{http_code}' \
    --max-time 90 -X POST http://litellm:4000/v1/embeddings \
    -H "Authorization: Bearer $K" -H 'Content-Type: application/json' \
    -d '{"model":"bge-m3","input":"post-boot check"}' 2>/dev/null || echo 000)
  [ "$CODE" = "200" ] && echo "gateway embeddings: 200" || FAILS+=("gateway embeddings HTTP ${CODE}")
fi

# 4. public chat surface
PC=$(curl -s -o /dev/null -w '%{http_code}' --max-time 25 https://chat.example.com/healthz 2>/dev/null || echo 000)
[ "$PC" = "200" ] && echo "public chat: 200" || FAILS+=("chat.example.com HTTP ${PC}")

# 5. governance evals
if /opt/homelab/ai/evals/run-evals.py >/tmp/postboot-evals.txt 2>&1; then
  echo "evals: $(grep -E 'passed .*blocking' /tmp/postboot-evals.txt | tail -1)"
else
  FAILS+=("eval suite FAILED: $(grep -E 'passed .*blocking' /tmp/postboot-evals.txt | tail -1)")
fi

# ---- report -----------------------------------------------------------------
KERN=$(uname -r)
if [ ${#FAILS[@]} -eq 0 ]; then
  echo "VERIFY OK"
  notify "✅ **jarvis maintenance complete** — rebooted onto kernel \`${KERN}\`. ${NOW} containers back, GPU OK, gateway OK, public chat OK, evals green."
else
  echo "VERIFY FAILED: ${FAILS[*]}"
  notify "⚠️ **jarvis post-reboot verification FAILED** (kernel \`${KERN}\`):
$(printf '• %s\n' "${FAILS[@]}")
Log: \`/srv/ai-data/backups/maintenance.log\`"
fi

rm -f "$MARKER"
