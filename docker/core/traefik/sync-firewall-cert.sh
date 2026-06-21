#!/bin/bash
# sync-firewall-cert.sh
# Push Traefik's wildcard cert (*.pdx.sanctioned.tech) to the EdgeRouter (firewall)
# GUI whenever Traefik renews it. The wildcard already covers firewall.pdx /
# home.pdx, so the router needs no ACME client of its own (port 80/443 are blocked).
#
# Runs as ROOT on jarvis (must read Traefik's acme.json). Deploys over SSH as the
# key-only 'certsync' admin user on the firewall. Idempotent: only acts when the
# leaf fingerprint changes. Wire via /etc/cron.d/fw-cert-sync. See README.md.
set -euo pipefail

AJ=/opt/homelab/core/traefik/letsencrypt/acme.json
MAIN=pdx.sanctioned.tech
FW_IP=192.168.2.1            # firewall eth2 on jarvis's subnet; the *name* resolves
                            # to 127.0.1.1 on jarvis (/etc/hosts), so use the IP.
KEY=/root/.ssh/fw_certsync
STATE=/opt/homelab/core/traefik/.fw-cert-fingerprint
LOG=/var/log/fw-cert-sync.log
SSHO=(-i "$KEY" -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=accept-new)

log(){ echo "$(date '+%F %T') $*" >> "$LOG"; }

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

# Extract wildcard fullchain + key from acme.json
jq -r --arg m "$MAIN" '.le.Certificates[]|select(.domain.main==$m)|.certificate' "$AJ" | base64 -d > "$tmp/full.pem"
jq -r --arg m "$MAIN" '.le.Certificates[]|select(.domain.main==$m)|.key'         "$AJ" | base64 -d > "$tmp/key.pem"
# Split: first cert = leaf (-> server.pem with key), remainder = chain (-> ca.pem)
awk '/BEGIN CERTIFICATE/{c++} {print > (d"/"(c==1?"leaf":"chain")".pem")}' d="$tmp" "$tmp/full.pem"
cat "$tmp/leaf.pem" "$tmp/key.pem" > "$tmp/server.pem"
cp "$tmp/chain.pem" "$tmp/ca.pem"

fp=$(openssl x509 -in "$tmp/leaf.pem" -noout -fingerprint -sha256 | cut -d= -f2)
if [ -f "$STATE" ] && [ "$(cat "$STATE")" = "$fp" ]; then
  exit 0   # unchanged since last deploy
fi

# Safety: refuse to push a key that doesn't match the cert
cm=$(openssl x509 -in "$tmp/leaf.pem" -noout -pubkey | openssl pkey -pubin -outform der | openssl dgst -sha256 | awk '{print $NF}')
km=$(openssl pkey -in "$tmp/key.pem" -pubout -outform der | openssl dgst -sha256 | awk '{print $NF}')
if [ "$cm" != "$km" ]; then log "ABORT: key/cert mismatch"; exit 1; fi

scp "${SSHO[@]}" "$tmp/server.pem" "$tmp/ca.pem" "certsync@${FW_IP}:/tmp/"
ssh "${SSHO[@]}" "certsync@${FW_IP}" '
  sudo cp /tmp/server.pem /config/ssl/server.pem &&
  sudo cp /tmp/ca.pem     /config/ssl/ca.pem &&
  sudo chown root:vyattacfg /config/ssl/server.pem /config/ssl/ca.pem &&
  sudo chmod 644 /config/ssl/server.pem /config/ssl/ca.pem &&
  rm -f /tmp/server.pem /tmp/ca.pem &&
  sudo systemctl restart lighttpd'

echo "$fp" > "$STATE"
log "deployed wildcard fp=$fp expires=$(openssl x509 -in "$tmp/leaf.pem" -noout -enddate | cut -d= -f2)"
