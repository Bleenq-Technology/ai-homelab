# smartctl Exporter
**Purpose:** Exposes per-drive **SMART** health/wear/temperature for Prometheus — the one
hardware signal `node-exporter`'s hwmon collector can't give us. Covers both physical drives:
the **Samsung 990 PRO** NVMe (`/dev/nvme0`) and the **Samsung 870 EVO** SATA SSD (`/dev/sda`).
**URL:** internal / no UI (metrics on `:9633`)
**Auth:** none (internal-only, not exposed via Traefik)
**Image:** `prometheuscommunity/smartctl-exporter:v0.14.0`
**Networks / data:** `monitoring`; scraped by Prometheus as the `smartctl` job.

## Why a dedicated exporter (not Telegraf)
SMART needs the `smartctl`/`nvme` binaries **and** raw block-device access (NVMe admin
passthrough + SAT for SATA). Our `telegraf` runs least-privilege (`user: telegraf`, only
`docker.sock` mounted) purely for the Docker container metrics — bolting privileged disk
access onto it would widen that blast radius. A small purpose-built exporter matches the
pattern already used here (node/nvidia/postgres/redis exporters), and it **auto-scans** all
drives (`smartctl --scan`), so a newly added disk appears with no config change.

## Setup as deployed
- `privileged: true` + `user: root` — required for the SMART ioctls; privileged also grants
  host `/dev` access so the scan sees the real drives. No volumes/env needed.
- Default flags: scans all devices, polls each scrape, serves Prometheus format on `:9633`.
  Tunables if needed: `--smartctl.interval` (poll cadence) and `--smartctl.rescan=<dur>`
  (re-scan for newly attached drives without a container restart).

## Metrics & alerts
Key series (all labelled `device="nvme0"` / `device="sda"`):
- `smartctl_device_temperature{temperature_type="current"}` — per-drive temp
- `smartctl_device_percentage_used` — **NVMe life used, 0–100** (>100 = past rated endurance)
- `smartctl_device_available_spare` / `_threshold` — **0–100** NVMe reserved-block headroom
- `smartctl_device_smart_status` — 1 = PASSED, 0 = FAILED
- `smartctl_device_media_errors` — uncorrected data-integrity events
- `smartctl_device_bytes_written` / `_bytes_read` — cumulative (TBW tracking)
- `smartctl_device_power_on_seconds`, `smartctl_device` (info: model/serial/firmware)

Alerts live in [../prometheus/alert_rules.yml](../prometheus/alert_rules.yml) group `disk-smart`
(SMART failing, NVMe wear >80%, NVMe spare <10%, media errors, drive temp >70/>80 C). Dashboard:
**Storage & Drives** (`jarvis-storage`).

## Fixes & gotchas
- **`device` labels are bare `nvme0` / `sda`** — NOT `/dev/nvme0` as the exporter's
  EXAMPLE.md shows (verified live on this v0.14.0 build 2026-06-24), and different from
  node-exporter's `node_disk_*` device names (which *are* `nvme0n1` / `sda`). The dashboard
  and alerts use each accordingly.
- **NVMe-only metrics are absent on the SATA drive.** `percentage_used`, `available_spare`,
  and `bytes_written` only exist for `nvme0`. The wear/spare alerts are **scoped to
  `device=~"nvme.*"`** so they can't match the SATA drive.
- **`percentage_used` / `available_spare` are 0–100, not 0–1 ratios** (verified live: a fresh
  nvme0 reads `percentage_used=0`, `available_spare=100`). Panels/alerts treat them as percent.

## Secrets
- None. No env keys consumed; nothing sensitive committed.
