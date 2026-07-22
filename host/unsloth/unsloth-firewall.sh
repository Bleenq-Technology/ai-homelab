#!/usr/bin/env bash
# ============================================================================
# Restrict the host LLM (unsloth Studio, :8888) to Docker + localhost.
#
# WHY (todos.md #39, docs/ai-governance.md control point 3):
# unsloth is started with `-H 0.0.0.0`, so before this it accepted connections
# from the ENTIRE LAN — every workstation, phone, and IoT-VLAN device could hit
# the shared model directly, bypassing the LiteLLM gateway and therefore every
# governance property we rely on: per-system virtual keys, tier rate limits, and
# the Langfuse trace. It is protected by UNSLOTH_API_KEY, but that is ONE static
# shared token with no per-consumer identity, no rotation, and no expiry, so it
# tells us nothing about WHO called.
#
# We cannot fix this with a bind address: LiteLLM reaches unsloth at the host's
# LAN IP (192.168.2.10:8888) from inside a Docker network, so binding to
# 127.0.0.1 would break the gateway, and binding to any single docker gateway
# would break the others. A port-scoped firewall rule is the correct control.
#
# The gateway path is untouched — this narrows WHO may reach the model, not how.
#
# Idempotent: uses a dedicated UNSLOTH-GUARD chain, flushed and rebuilt each run.
# Applied at boot by unsloth-firewall.service (iptables rules are not persistent).
#
# Deploy: see host/unsloth/README.md
# ============================================================================
set -euo pipefail

PORT="${UNSLOTH_PORT:-8888}"
CHAIN="UNSLOTH-GUARD"
# All Docker bridge networks live in 172.16.0.0/12 (ai/data/proxy/monitoring/...).
# Our LAN is 192.168.2.0/24, so there is no overlap.
DOCKER_NETS="${DOCKER_NETS:-172.16.0.0/12}"

need_root() { [ "$(id -u)" -eq 0 ] || { echo "must run as root (sudo)" >&2; exit 1; }; }
need_root

# Build the chain fresh so re-running never stacks duplicate rules.
iptables -N "$CHAIN" 2>/dev/null || iptables -F "$CHAIN"

iptables -A "$CHAIN" -i lo -j ACCEPT                       # host-local callers
iptables -A "$CHAIN" -s 127.0.0.0/8 -j ACCEPT
iptables -A "$CHAIN" -s "$DOCKER_NETS" -j ACCEPT           # LiteLLM + any ai-net service
# REJECT, not DROP: a fast "connection refused" is far easier to diagnose than a
# hang, and stealth buys nothing on our own LAN.
iptables -A "$CHAIN" -p tcp -j REJECT --reject-with tcp-reset
iptables -A "$CHAIN" -j REJECT

# Hook it in ONCE, at the top of INPUT, scoped to this port only. Everything
# else on the host (SSH included) is untouched — check before insert so repeat
# runs don't add a second jump.
if ! iptables -C INPUT -p tcp --dport "$PORT" -j "$CHAIN" 2>/dev/null; then
  iptables -I INPUT 1 -p tcp --dport "$PORT" -j "$CHAIN"
fi

echo "unsloth :$PORT restricted to lo + $DOCKER_NETS"
iptables -L "$CHAIN" -n --line-numbers
