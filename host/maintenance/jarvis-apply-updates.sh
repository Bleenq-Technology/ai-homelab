#!/usr/bin/env bash
# ============================================================================
# Scheduled OS maintenance for jarvis: apply pending apt updates, then reboot.
#
# WHY THIS EXISTS: `unattended-upgrades` is enabled with Automatic-Reboot
# "false", so security patches install automatically but the box NEVER reboots —
# reboot debt accumulates silently (found 2026-07-23: kernel 7.0.0-28 installed
# while running -27, 170 pkgs / 24 security pending). This closes the loop on a
# schedule instead of by surprise.
#
# SAFETY PROPERTIES:
#   * Fully non-interactive. Keeps existing config files on conflict
#     (--force-confold) so a package can't silently replace a tuned config.
#   * NEEDRESTART_MODE=l — needrestart only LISTS services; it must not bounce
#     services mid-upgrade, because we're rebooting anyway and a half-restarted
#     stack is worse than a clean reboot.
#   * If apt FAILS it does NOT reboot — rebooting a half-upgraded system is how
#     you turn a bad update into an outage. It alerts and leaves the host up.
#   * Snapshots the running container set first so post-boot verification can
#     prove everything came back (not just "docker is up").
#
# FIRMWARE IS DELIBERATELY NOT TOUCHED. The only fwupd offer is a Secure Boot
# KEK cert update, and Secure Boot is DISABLED on this host — zero benefit. The
# System Firmware (BIOS) itself has no update. See host/maintenance/README.md.
#
# Deploy: see host/maintenance/README.md
# ============================================================================
set -uo pipefail

LOG=/srv/ai-data/backups/maintenance.log
STATE=/var/lib/jarvis-maint
ENV_FILE=/opt/homelab/.env
mkdir -p "$STATE"
exec >>"$LOG" 2>&1

echo "===== $(date -Is) maintenance run starting (kernel $(uname -r)) ====="

notify() {  # $1 = message; never fatal — a failed alert must not abort maintenance
  local url payload
  url=$(grep -E '^DISCORD_WEBHOOK_URL=' "$ENV_FILE" 2>/dev/null | head -1 | cut -d= -f2-)
  [ -n "${url:-}" ] || { echo "notify: no webhook configured"; return 0; }
  payload=$(python3 -c 'import json,sys; print(json.dumps({"content": sys.argv[1]}))' "$1")
  curl -sf -m 20 -H 'Content-Type: application/json' -d "$payload" "$url" >/dev/null \
    || echo "notify: webhook post failed (non-fatal)"
}

# ---- snapshot pre-reboot state (what must come back) ------------------------
docker ps --format '{{.Names}}' 2>/dev/null | sort >"$STATE/pre-reboot-containers.txt" || true
PRE=$(wc -l <"$STATE/pre-reboot-containers.txt" 2>/dev/null || echo 0)
echo "$PRE" >"$STATE/pre-reboot-count.txt"
echo "pre-reboot: $PRE containers running"

# ---- apply updates ---------------------------------------------------------
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=l

apt-get update -qq || { echo "apt-get update failed"; notify "⚠️ **jarvis maintenance ABORTED** — \`apt-get update\` failed. No changes made, no reboot."; exit 1; }

PENDING=$(apt-get -s full-upgrade 2>/dev/null | grep -c '^Inst ' || echo 0)
echo "packages to upgrade: $PENDING"

if ! apt-get -y \
      -o Dpkg::Options::="--force-confdef" \
      -o Dpkg::Options::="--force-confold" \
      full-upgrade; then
  echo "!! apt full-upgrade FAILED — NOT rebooting"
  notify "⚠️ **jarvis maintenance FAILED** during \`apt full-upgrade\` — **did NOT reboot** (a half-upgraded reboot is worse than none). Host still up on kernel \`$(uname -r)\`. Log: \`/srv/ai-data/backups/maintenance.log\`"
  exit 1
fi

apt-get -y autoremove --purge >/dev/null 2>&1 || true
echo "apt full-upgrade OK ($PENDING packages)"

# ---- arm post-boot verification, then reboot -------------------------------
touch "$STATE/verify-after-boot"
NEWK=$(find /boot -maxdepth 1 -name 'vmlinuz-*' -printf '%f\n' 2>/dev/null | sed 's/vmlinuz-//' | sort -V | tail -1)
notify "🔧 **jarvis maintenance**: $PENDING packages upgraded OK. Rebooting into kernel \`${NEWK:-?}\` (was \`$(uname -r)\`). Verification will report in ~3 min."
echo "rebooting now; post-boot verification armed"
sync
sleep 5
systemctl reboot
