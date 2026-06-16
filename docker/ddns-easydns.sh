#!/usr/bin/env bash
# Dynamic DNS via the EasyDNS REST API — keep firewall.pdx.sanctioned.tech (and
# the vpn.pdx CNAME pointing at it) tracking this host's WAN IP, so the WireGuard
# VPN endpoint stays reachable on a dynamic residential IP. Reuses the ACME
# EasyDNS credentials in secrets/ (token = REST user, key = REST password).
#
# Cron (every 5 min):
#   */5 * * * * /opt/homelab/ddns-easydns.sh >> /opt/homelab/ddns-easydns.log 2>&1
#
# Note: EasyDNS REST quirks — GET /zones/records/{id} reads a record; *POST*
# /zones/records/{id} UPDATES it (PUT is add-only and 404s for an update).
set -euo pipefail
cd "$(dirname "$0")"

TOKEN=$(cat secrets/easydns_token)
KEY=$(cat secrets/easydns_key)
RECORD_ID=129458551          # firewall.pdx A  (vpn.pdx is a CNAME -> firewall.pdx)
HOST=firewall.pdx
DOMAIN=sanctioned.tech
API=https://rest.easydns.net
CACHE=.ddns-last-ip

ip=$(curl -s -m 15 https://api.ipify.org)
[[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || { echo "$(date '+%F %T') WARN: bad WAN IP '$ip'"; exit 1; }
[[ "$ip" == "$(cat "$CACHE" 2>/dev/null || true)" ]] && exit 0   # unchanged since last run

status=$(curl -s -m 20 -u "$TOKEN:$KEY" -X POST "$API/zones/records/$RECORD_ID?format=json" \
  -H 'Content-Type: application/json' \
  -d "{\"host\":\"$HOST\",\"type\":\"A\",\"rdata\":\"$ip\",\"ttl\":\"300\",\"domain\":\"$DOMAIN\"}" \
  | python3 -c 'import sys,json;print(json.load(sys.stdin).get("status"))' 2>/dev/null || echo "?")

if [[ "$status" == "200" ]]; then
  printf '%s' "$ip" > "$CACHE"
  echo "$(date '+%F %T') updated $HOST.$DOMAIN -> $ip"
else
  echo "$(date '+%F %T') ERROR updating $HOST.$DOMAIN -> $ip (status $status)"; exit 1
fi
