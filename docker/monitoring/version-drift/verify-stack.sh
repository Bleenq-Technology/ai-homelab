#!/usr/bin/env bash
# ============================================================================
# Snapshot / verify the stack around a change. Built for container upgrades but
# useful before ANY risky change.
#
# WHY A SNAPSHOT AND NOT JUST HEALTH CHECKS. "58 containers are running" can be
# true while the wrong one is down — a count matches after a container silently
# fails and another is started. So --snapshot records the container set BY NAME
# and by image tag, and --verify diffs against it. Same discipline as
# host/maintenance/jarvis-post-boot-verify.sh, which this deliberately mirrors.
#
# The checks are chosen as the ones whose silent failure would cost the most:
# the GPU (a driver/kernel mismatch kills bge-m3 + ComfyUI), a real embeddings
# round-trip through the gateway (a port being open proves nothing), the public
# chat surface, the governance eval suite, and the Prometheus rules parsing.
#
#   ./verify-stack.sh --snapshot     # before you change anything
#   ./verify-stack.sh --verify       # after; diffs + checks; non-zero on failure
# ============================================================================
set -uo pipefail

STATE="${STATE:-/srv/ai-data/upgrade}"
ENV_FILE="${ENV_FILE:-/opt/homelab/.env}"
SNAP="$STATE/containers.txt"
IMGS="$STATE/images.txt"
mkdir -p "$STATE"

mode="${1:---verify}"

if [ "$mode" = "--snapshot" ]; then
  docker ps --format '{{.Names}}' | sort > "$SNAP"
  docker ps --format '{{.Names}}\t{{.Image}}' | sort > "$IMGS"
  echo "snapshot: $(wc -l < "$SNAP") containers -> $SNAP"
  echo "run the upgrade, then: $0 --verify"
  exit 0
fi

[ -f "$SNAP" ] || { echo "no snapshot at $SNAP — run --snapshot first"; exit 2; }

FAILS=()
echo "== verifying against snapshot taken $(date -r "$SNAP" -Is 2>/dev/null) =="

# ---- 1. every container that was up is up again, BY NAME --------------------
NOW=$(docker ps --format '{{.Names}}' | sort)
MISSING=$(comm -23 "$SNAP" <(printf '%s\n' "$NOW") | tr '\n' ' ')
if [ -n "${MISSING// /}" ]; then
  FAILS+=("containers NOT back: ${MISSING}")
else
  echo "  containers: $(printf '%s\n' "$NOW" | grep -c .) up, none missing"
fi

# ---- 2. what actually changed image (the point of the exercise) -------------
echo "  image changes:"
diff <(cut -f2 "$IMGS" | sort -u) <(docker ps --format '{{.Image}}' | sort -u) \
  | grep -E '^[<>]' | sed 's/^/    /' || echo "    (none)"

# ---- 3. GPU ----------------------------------------------------------------
if nvidia-smi -L >/dev/null 2>&1; then
  echo "  gpu: $(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1)"
else
  FAILS+=("nvidia-smi failed — bge-m3 + ComfyUI affected")
fi

# ---- 4. gateway serves (embeddings round-trip, not just a port) -------------
K=$(grep -E '^EVALS_LLM_KEY=' "$ENV_FILE" 2>/dev/null | head -1 | cut -d= -f2-)
if [ -n "${K:-}" ]; then
  CODE=$(docker run --rm --network ai curlimages/curl:8.11.1 -s -o /dev/null -w '%{http_code}' \
    --max-time 90 -X POST http://litellm:4000/v1/embeddings \
    -H "Authorization: Bearer $K" -H 'Content-Type: application/json' \
    -d '{"model":"bge-m3","input":"upgrade check"}' 2>/dev/null || echo 000)
  [ "$CODE" = "200" ] && echo "  gateway embeddings: 200" || FAILS+=("gateway embeddings HTTP ${CODE}")
fi

# ---- 5. public surface ------------------------------------------------------
PC=$(curl -s -o /dev/null -w '%{http_code}' --max-time 25 https://chat.example.com/healthz 2>/dev/null || echo 000)
[ "$PC" = "200" ] && echo "  public chat: 200" || FAILS+=("chat.example.com HTTP ${PC}")

# ---- 6. governance evals (catches a silently-disabled guardrail) ------------
if /opt/homelab/ai/evals/run-evals.py >/tmp/upgrade-evals.txt 2>&1; then
  echo "  evals: $(grep -E 'passed .*blocking' /tmp/upgrade-evals.txt | tail -1)"
else
  FAILS+=("eval suite FAILED: $(grep -E 'passed .*blocking' /tmp/upgrade-evals.txt | tail -1)")
fi

# ---- 7. prometheus rules still parse (a bad bump breaks alerting silently) --
if docker ps --format '{{.Names}}' | grep -qx prometheus; then
  if docker exec prometheus promtool check rules /etc/prometheus/alert_rules.yml >/tmp/pt.txt 2>&1; then
    echo "  prometheus rules: $(grep -oE '[0-9]+ rules found' /tmp/pt.txt | head -1)"
  else
    FAILS+=("promtool check rules FAILED — alerting may be degraded")
  fi
fi

# ---- 8. AI-BOM drift (catches a guardrail or key that vanished) -------------
if [ -x /opt/homelab/ai/inventory/build-ai-bom.py ]; then
  if /opt/homelab/ai/inventory/build-ai-bom.py --live --check >/tmp/bom.txt 2>&1; then
    echo "  ai-bom: $(grep -E 'fail ·' /tmp/bom.txt | tail -1 | sed 's/^ *//')"
  else
    FAILS+=("AI-BOM drift check FAILED: $(grep -E 'fail ·' /tmp/bom.txt | tail -1)")
  fi
fi

echo
if [ ${#FAILS[@]} -eq 0 ]; then
  echo "VERIFY OK"
  exit 0
fi
printf 'VERIFY FAILED:\n'
printf '  - %s\n' "${FAILS[@]}"
exit 1
