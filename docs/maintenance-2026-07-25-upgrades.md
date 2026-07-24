<!-- Working runbook for a specific dated window. Not a standing doc — archive or
     delete after the window is done and the outcome is recorded below. -->
# Container upgrade window — Saturday 2026-07-25

**Window:** Sat 2026-07-25, **09:00–11:00 PT** (16:00–18:00 UTC). **Attended.**
**Owner:** Paul. **Rollback budget:** each step is independently revertible.

## Why this slot

- **Clear of every scheduled job.** The only recurring cron block is 02:00–05:30 UTC (backup, audit,
  evals, weekly BOM/egress/models, discord resync); the Mon jobs (oversight 15:00, drift 16:00) are
  two days out. Saturday daytime is empty.
- **~21h of soak before the unattended OS reboot** (`jarvis-maintenance.timer`, **Sun 13:00 UTC**).
  Anything subtle surfaces while a human is watching — and if the upgrades look shaky, Sunday's
  window can be cancelled (`sudo systemctl disable --now jarvis-maintenance.timer`) without losing
  the OS-patch work, which reschedules.
- Daytime = lowest public-chat traffic, and someone is awake to read Discord.

## Scope — Tier 1 only (14 images), unless time allows starting Tier 2

Tier 1 is the low-blast-radius set: independent services, trivial rollback. **Tier 2 (LiteLLM,
Keycloak, Infisical, the datastores) is NOT in this window** — those need one-at-a-time verification
and are better as their own attended session. Full tiered list: `docs/` commit history / the drift
check output.

| # | Image | → | Watch after |
|---|---|---|---|
| 1 | prom/node-exporter | 1.12.1 | metrics still scraping |
| 2 | prom/alertmanager | 0.33.1 | a test alert still routes to Discord |
| 3 | prometheuscommunity/postgres-exporter | 0.20.1 | pg metrics |
| 4 | oliver006/redis_exporter | 1.88.0 | redis metrics |
| 5 | utkuozdemir/nvidia_gpu_exporter | 1.13.0 | GPU metrics (big jump) |
| 6 | telegraf | 1.39.2 | — |
| 7 | grafana/loki | 3.7.4 | log ingest continues |
| 8 | dpage/pgadmin4 | 9.16 | login |
| 9 | portainer/portainer-ce | 2.43.0 | login |
| 10 | ghcr.io/homarr-labs/homarr | 1.71.0 | dashboard loads |
| 11 | baserow/baserow | 2.3.3 | login |
| 12 | redpandadata/console | 3.9.0 | UI (not the broker) |
| 13 | **adguard/adguardhome** | 0.107.78 | **LAN DNS — do LAST, watch resolution** |

> **AdGuard is the one with teeth in Tier 1.** Container DNS forwards through it. Do it last, and have
> the rollback command already typed. If resolution breaks, containers lose DNS.

## Procedure per image

```bash
# 0. once, at the start:
/opt/homelab/monitoring/version-drift/verify-stack.sh --snapshot

# per image:
docker pull <image>:<newtag>                       # pull first — no downtime yet
#   edit the pin in the compose file (repo, then scp to /opt/homelab), OR sed on host + backport
cd /opt/homelab && docker compose -f compose.yml up -d <service>
docker ps --filter name=<service>                  # healthy?
docker logs <service> --since 2m | grep -iE 'error|fatal'

# rollback if bad: put the old tag back, up -d again. (Images aren't pruned mid-window.)

# 1. at the end:
/opt/homelab/monitoring/version-drift/verify-stack.sh --verify
/opt/homelab/monitoring/version-drift/check-image-versions.py   # confirm the count dropped
```

**Deploy discipline (CLAUDE.md):** the pins live in this repo's compose files. Edit there, `scp` the
changed file to `/opt/homelab`, then `chmod g+rwX`. Don't hand-edit only on the host — it drifts from
git. (Monitoring images are all in `docker/monitoring/compose.monitoring.yml`; adguard in its own.)

## Pre-window (do NOT let these block the upgrades)

- [ ] **`kb_homelab_docs` is missing from Qdrant** — found 2026-07-24 by `verify-stack.sh`, **unrelated
  to any upgrade** (nothing touched Qdrant). Every other `kb_*` collection is present; only this one is
  gone, and `kb-ingest` (n8n, active) has no recorded executions. The advisory eval
  `kb-retrieval-finds-known-answer` has been failing as a result. **Rebuild via the kb-ingest workflow
  and confirm the eval goes green** — separate thread from the window, but do it first so the harness's
  baseline is clean going in.

## Rollback (whole window)

Every image was pulled, not built, so the old tag is still local. Revert = restore the old tag in the
compose file, `up -d <service>`. No datastore in Tier 1 changes on-disk format, so there's no
one-way door in this set (that caution is a Tier 2 concern — see the minio bump notes).

## Outcome (fill in after)

- Completed: …
- Rolled back: …
- Behind count before → after: 30 → …
- Sunday OS window kept / cancelled: …
