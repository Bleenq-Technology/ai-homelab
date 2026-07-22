#!/usr/bin/env bash
# ============================================================================
# Shadow-AI egress detection (todos.md #39, docs/ai-governance.md control pt. 3)
#
# THE PROBLEM: every governance property we rely on — per-system virtual keys,
# tier rate limits, Langfuse traces, the AI inventory — holds ONLY for traffic
# that voluntarily goes through LiteLLM. Container egress is unrestricted, so any
# container with a cloud API key in its env can call a frontier model with zero
# trace, zero record, and our data in the request body. That is the difference
# between a gateway (a paved road) and a chokepoint.
#
# THIS SCRIPT IS DETECTION, NOT ENFORCEMENT. It answers two questions:
#   1. CAPABILITY — is the path from our Docker networks to a public LLM provider
#      open right now? (active probe)
#   2. USAGE — has anything on the network actually resolved a provider hostname
#      recently? (passive, from AdGuard's query log)
#
# HONEST LIMITATIONS, so nobody mistakes this for more than it is:
#   - AdGuard records the CLIENT as the router (192.168.2.1) because container
#     DNS is forwarded host -> resolved -> router -> AdGuard. So usage detection
#     tells us THAT a provider was resolved, not WHICH container did it. Real
#     per-container attribution needs either a dedicated resolver per Docker
#     network or connection-level logging — a larger piece of work.
#   - A normal browser visiting chatgpt.com on the LAN also lights this up. Treat
#     a hit as "look at this", not "incident".
#   - Blocking is deliberately NOT done here. DNS-level blocking at AdGuard would
#     hit every LAN client including a human using ChatGPT in a browser (wrong),
#     and IP-level blocking is unreliable because provider endpoints are
#     CDN-fronted and rotate. Enforcement needs a per-network egress proxy that
#     only LiteLLM may bypass — staged as the second half of #39.
#
# Usage:  ./check-egress.sh [--publish]
# ============================================================================
set -uo pipefail

TEXTFILE_DIR="${TEXTFILE_DIR:-/var/lib/node_exporter/textfile}"
ADGUARD_LOG="${ADGUARD_LOG:-/opt/adguardhome/work/data/querylog.json}"
LOOKBACK_DAYS="${LOOKBACK_DAYS:-7}"
PROBE_IMAGE="${PROBE_IMAGE:-curlimages/curl:8.11.1}"
PUBLISH=0
[ "${1:-}" = "--publish" ] && PUBLISH=1

# Endpoints that indicate a model call bypassing our gateway. Extend as new
# providers appear — an unlisted provider is an undetected one.
PROVIDERS=(
  "api.openai.com"
  "api.anthropic.com"
  "generativelanguage.googleapis.com"
  "api.mistral.ai"
  "api.cohere.ai"
  "api.groq.com"
  "api.together.xyz"
  "openrouter.ai"
)

# Networks whose containers should NEVER need to reach a provider directly.
# LiteLLM is the sanctioned exception and lives on `ai` — today it has NO cloud
# provider configured at all (local unsloth + bge-m3 only), so a hit from any of
# these is unexplained by design.
NETWORKS=("${EGRESS_NETWORKS:-ai data monitoring}")

echo "== shadow-AI egress detection =="
echo

open_paths=0
echo "-- capability: can a container reach a public LLM provider? --"
for net in ${NETWORKS[*]}; do
  docker network inspect "$net" >/dev/null 2>&1 || { echo "  ($net: no such network, skipping)"; continue; }
  for p in "${PROVIDERS[@]}"; do
    code=$(docker run --rm --network "$net" "$PROBE_IMAGE" \
             -s -o /dev/null -w '%{http_code}' --max-time 6 "https://$p/" 2>/dev/null || echo 000)
    # Any HTTP response at all means the path is open — 401/403/404 still proves
    # reachability. Only a connection failure (000) means it is closed.
    if [ "$code" != "000" ]; then
      echo "  OPEN   $net -> $p  (HTTP $code)"
      open_paths=$((open_paths + 1))
    else
      echo "  closed $net -> $p"
    fi
  done
done

echo
echo "-- usage: provider hostnames resolved in the last ${LOOKBACK_DAYS}d (AdGuard) --"
usage_hits=0
if docker ps --format '{{.Names}}' | grep -qx adguard; then
  since=$(date -u -d "-${LOOKBACK_DAYS} days" +%Y-%m-%d 2>/dev/null || echo "")
  for p in "${PROVIDERS[@]}"; do
    n=$(docker exec adguard sh -c "grep -F '\"QH\":\"$p\"' '$ADGUARD_LOG' 2>/dev/null | wc -l" 2>/dev/null | tr -d '[:space:]')
    n=${n:-0}
    if [ "$n" -gt 0 ] 2>/dev/null; then
      echo "  SEEN   $p  ($n queries in the retained log)"
      usage_hits=$((usage_hits + n))
    fi
  done
  [ "$usage_hits" -eq 0 ] && echo "  (no provider hostnames resolved)"
  echo "  NOTE: client attribution is the router, not the container — see header."
else
  echo "  (adguard not running; usage detection unavailable)"
fi

echo
echo "== $open_paths open path(s), $usage_hits provider DNS query/queries =="

if [ "$PUBLISH" = "1" ]; then
  if [ ! -d "$TEXTFILE_DIR" ]; then
    echo "metrics: SKIP (no $TEXTFILE_DIR)" >&2
  elif [ ! -w "$TEXTFILE_DIR" ]; then
    # Present-but-unwritable is the dangerous case: absent() never fires because
    # the stale file is still scraped. Same trap as todos.md #11.
    echo "[ERROR] metrics: $TEXTFILE_DIR NOT WRITABLE by $(id -un) — results will go STALE SILENTLY" >&2
  else
    tmp="$TEXTFILE_DIR/.homelab_ai_egress.prom.$$"
    {
      echo "# HELP homelab_ai_egress_open_paths Container->public-LLM-provider paths currently reachable."
      echo "# TYPE homelab_ai_egress_open_paths gauge"
      echo "homelab_ai_egress_open_paths $open_paths"
      echo "# HELP homelab_ai_egress_provider_dns_queries Provider hostnames resolved in the retained AdGuard log."
      echo "# TYPE homelab_ai_egress_provider_dns_queries gauge"
      echo "homelab_ai_egress_provider_dns_queries $usage_hits"
      echo "# HELP homelab_ai_egress_last_run_timestamp_seconds Unix time of the last egress check."
      echo "# TYPE homelab_ai_egress_last_run_timestamp_seconds gauge"
      echo "homelab_ai_egress_last_run_timestamp_seconds $(date +%s)"
    } > "$tmp" && mv -f "$tmp" "$TEXTFILE_DIR/homelab_ai_egress.prom"
    echo "metrics: wrote homelab_ai_egress.prom (open_paths=$open_paths)"
  fi
fi

# Exit 0 always: this is a REPORTING control. The path being open is the known,
# documented state today (#39) — failing the run would just train us to ignore it.
exit 0
