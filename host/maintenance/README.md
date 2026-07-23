# Scheduled OS maintenance (jarvis)

**Purpose:** apply pending apt updates and take the pending reboot on a *scheduled* window, then
**prove the stack came back**. **URL:** none (systemd timer + two scripts on the host).

## Why this exists

`unattended-upgrades` is enabled with **`Automatic-Reboot "false"`** — security patches install
automatically but the box **never reboots**, so reboot debt accumulates silently. Found 2026-07-23:
kernel **7.0.0-28 installed while running -27**, 170 packages / 24 security pending. This closes the
loop deliberately instead of by surprise.

## The 2026-07-23 assessment (why the plan looks like this)

| Question | Finding |
|---|---|
| **Firmware?** | **Skipped — deliberately.** The only `fwupdmgr` offer is a Secure Boot **KEK certificate** update (2011→2023, 2.8 kB), and **Secure Boot is DISABLED** on this host → zero benefit. **System Firmware (BIOS) has no update**, nor do either SSD. Revisit only if Secure Boot is ever enabled. |
| **Anything urgent?** | **No.** Of 24 security patches, none are the high-severity remote surfaces (no OpenSSH/OpenSSL/sudo/glibc). Notable: **PAM** + **krb5** (auth-adjacent), plus `tar`, `rsyslog`, `gawk`, image/media libs. |
| **GPU risk?** | **Clear — checked.** `linux-modules-nvidia-595-server-open-7.0.0-28` is **already installed**, so booting the new kernel keeps the GPU (bge-m3 + ComfyUI) alive. The **NVIDIA driver is NOT upgrading** (0 `nvidia-*`); only the CUDA *toolkit* (37 pkgs), which is host dev tooling — containers ship their own CUDA runtime. |
| **What actually interrupts?** | **docker-ce + containerd** (6 pkgs) → daemon restart bounces all ~59 containers, and the **reboot**. Everything else is non-disruptive. |
| **Dry-run** | 135 actions, **0 removals** — nothing gets uninstalled. |

## The schedule

**One-shot: Sunday 2026-07-26 06:00 PT.** Chosen to miss the dense 02:00–05:30 cron block (backup
02:00, audit export 02:30, evals 03:10, weekly AI-BOM/egress/models 03:30–04:00, kb-ingest 04:00,
dc-resync 05:30), avoid market hours / the weekday 21:30 scanner run, and hit lowest public-chat traffic.

```bash
systemctl list-timers jarvis-maintenance.timer   # -> Sun 2026-07-26 13:00 UTC (= 06:00 PDT)
```

> **The timezone suffix in `OnCalendar` is load-bearing.** This host's clock is **UTC**, so a bare
> `06:00` would fire at **23:00 Saturday Pacific**. The explicit `America/Los_Angeles` also makes it
> DST-safe (same pattern as the scanner nightly timer).

## What it does

1. **Snapshots the running container set by name** (so verification proves the *right* things came
   back — a count can match while the wrong container is down).
2. `apt-get full-upgrade`, fully non-interactive, `--force-confold` (never silently replace a tuned
   config), `NEEDRESTART_MODE=l` (needrestart lists only — it must not bounce services mid-upgrade
   when we're rebooting anyway).
3. **On apt failure: alerts and does NOT reboot.** Rebooting a half-upgraded system turns a bad
   update into an outage.
4. On success: arms the post-boot marker and reboots.
5. **After boot**, `jarvis-post-boot-verify.service` proves the restore side: every pre-reboot
   container back **by name**, `nvidia-smi`, a real **embeddings round-trip** through the gateway,
   `chat.example.com/healthz`, and the **governance eval suite**. Reports ✅ or ⚠️ to Discord.

"It booted" is not the bar — same discipline as `verify-backups.sh`.

## Operating it

```bash
# reschedule (edit OnCalendar, then)
sudo systemctl daemon-reload && sudo systemctl restart jarvis-maintenance.timer

# cancel
sudo systemctl disable --now jarvis-maintenance.timer

# run it NOW instead of waiting
sudo systemctl start jarvis-maintenance.service     # NB: this upgrades AND reboots

# watch / after-action
tail -f /srv/ai-data/backups/maintenance.log
```

**Do not `systemctl enable jarvis-maintenance.service`** — enabling the *service* would run
maintenance (and reboot) on every boot. Only the **timer** is enabled.

`Persistent=false` is deliberate: if the host is down at the window, it must **not** fire a surprise
upgrade+reboot at the next boot. A missed window gets rescheduled by a human.

## Gotchas

- Alerting was **verified before relying on it** (test POST → HTTP 204). An unattended job whose
  alert path is silently broken is worse than no job.
- The post-boot verify is **gated on a marker file**, so ordinary reboots don't generate Discord noise.
- A fixed *date* in `OnCalendar` makes this genuinely one-shot — systemd fires it once and the timer
  goes elapsed. To make it recurring monthly, use e.g. `OnCalendar=Sun *-*-01..07 06:00 America/Los_Angeles`.
