# Container image drift check

**Purpose:** answer "how far behind is what we're actually running?" on a schedule instead of by eye.
**URL:** none (weekly cron + Prometheus metrics). **Changes nothing** — it reports.

## Why

We pin every image on purpose (`CLAUDE.md`: no `:latest`). That's correct, and it means nothing ever
updates unless a human notices. On **2026-07-24** a manual sweep found **cloudflared 17 months old**
(it terminates the public tunnels) and **minio 15 months** (a Keycloak OIDC client). Neither was a
decision — both were drift. *Pinning without a drift check is a slower way to run old software.*

```bash
./check-image-versions.py             # report
./check-image-versions.py --publish   # + Prometheus textfile metrics
```
**Schedule:** `0 16 * * 1` (Mon 16:00 UTC). Log: `/srv/ai-data/backups/image-drift.log`.

## What it classifies, and why the buckets matter

Images come from `docker ps`, so this reflects **what is running**, not what a compose file says.

| Bucket | Meaning |
|---|---|
| `behind` | A newer release exists **on the pinned major track** |
| `current` | Newest on its track |
| `digest` | `sha-7bb1d58` — content-addressed, the strictest pin there is |
| `floating` | `:latest`, `:2-alpine` — **can change on any recreate** |
| `local` | Compose-built (`web-app-bff-…`) — no upstream to compare |
| `unknown` | Registry not queryable. **Not a clean bill of health** |

Three distinctions the first version got wrong, each of which would have made the check ignorable:

1. **Arch/variant tags are not newer versions.** `v7.15.3-s390x`, `13.1.1-distroless`,
   `2.11.4-nanoserver` are the same release built differently. Including them invents upgrades.
2. **A pinned major is a decision, not drift.** `postgres:16.14` and `redis:7.4.9-alpine` are
   deliberate tracks. Newer majors are reported **separately**, as information.
3. **`16.14` is not a floating tag.** An early pass flagged `postgres:16.14` and `pgadmin4:9.15` as
   unpinned because they have two components. Only named channels (`latest`, `main`) and
   **major-only** tags (`3`, `2-alpine`) actually move.

`unknown` is a deliberate bucket, never folded into "fine": a failed registry query must not look
like a pass. MinIO's `RELEASE.<ISO-date>` tags are handled explicitly — they're not semver, but they
sort correctly as strings, and "unknown" was the wrong answer for the image that was 15 months stale.

## Metrics + alerts

`homelab_image_versions_{total,behind,floating,unknown,last_run_timestamp_seconds}`

Alert group `image-drift` in [`alert_rules.yml`](../prometheus/alert_rules.yml):

- **`ImageDriftCheckStale`** / **`ImageDriftMetricsMissing`** — dead-man on the check.
- **`ImageTagsFloating`** — fires on any floating tag, because an image that changes under a recreate
  isn't reproducible and has no rollback target.

> **`_behind > 0` is deliberately NOT alerted.** 30 images are behind right now and that's fine —
> upgrading is a scheduled decision, not a page. An alert that fires permanently is one that's
> permanently ignored.

## Upgrading (what this check is for)

Do it in tiers, never as one sweep:

1. **Independent services first** — cloudflared, minio, exporters, prometheus, qdrant. Easy rollback.
2. **One at a time, verify after each** — LiteLLM, Open WebUI, Keycloak, Langfuse.
3. **Leave deliberate major pins alone** — postgres 16, redis 7.

> ⚠️ **LiteLLM is the sharp one.** The guardrail `category_file` bind-mounts embed **`python3.13`** in
> their path. If an image bumps Python, those mounts land nowhere, LiteLLM **warns-and-skips and
> starts healthy** — guardrails silently gone. Run `ai/evals/run-evals.py` immediately after any
> LiteLLM upgrade; `guardrail-blocks-injection` is blocking precisely for this.
>
> Also note LiteLLM's `-stable` channel tops out well below the mainline tags — we run mainline, so
> "latest stable" is ambiguous for that image specifically.

**Don't fold container upgrades into the OS maintenance window** (`host/maintenance/`). Mixing a
kernel reboot with a batch of image bumps makes failure attribution guesswork.
