# AI inventory / AI-BOM

**Purpose:** Control point 4 — *what is approved to exist*. Joins the human-owned inventory against
live platform state and **fails when they disagree**.
**URL:** none (a script, not a service)
**Networks / data:** runs on the jarvis host; reaches LiteLLM/Qdrant/n8n over their `.pdx` URLs and
ClickHouse via `docker exec`.

Context: [`docs/ai-governance.md`](../../../docs/ai-governance.md) ·
tiers + matrix: [`docs/ai-risk-tiers.md`](../../../docs/ai-risk-tiers.md) · backlog: `todos.md` #36/#37.

## The two halves

| File | Owned by | Holds |
|---|---|---|
| [`docs/ai-inventory.yml`](../../../docs/ai-inventory.yml) | **humans** | Intent: systems, owners, tiers, oversight points, accepted risks |
| [`docs/ai-bom.md`](../../../docs/ai-bom.md) / `.json` | **generated** | Intent joined against reality. Never hand-edit |

Edit the inventory; regenerate the BOM.

## Running it

```bash
# static — no platform access, runs in CI on every PR
python3 docker/ai/inventory/build-ai-bom.py --check

# full — on jarvis (needs /opt/homelab/.env)
/opt/homelab/ai/inventory/build-ai-bom.py --live --check --write --publish
```

`--check` exits non-zero on any FAIL · `--write` regenerates the BOM · `--publish` emits
`homelab_ai_bom_*` to node-exporter's textfile collector.

**Static vs live is a real split, not laziness:** CI cannot reach jarvis's internal networks, so it
validates what needs no platform access (schema, owners, tiers, master-key use, statically-decidable
matrix rows). Everything needing the platform — credential existence, budgets, rate limits, expiry,
corpus reality, trace attribution — runs weekly on jarvis.

## What it checks

**FAIL** (breaks the build / fires the alert):

| Code | Meaning |
|---|---|
| `unregistered_credential` | A LiteLLM key exists with no inventory entry — **shadow AI** |
| `unregistered_trace_source` | Langfuse traces from a system nobody registered |
| `stale_entry` | An entry declares a key that no longer exists |
| `master_key_use` | A system runs on the master key — unscoped, unbounded, unattributable |
| `missing_owner` / `unknown_owner` / `bad_tier` / `duplicate_entry` | Inventory integrity |
| `missing_budget` / `missing_rate_limit` / `missing_expiry` / `missing_oversight` | Control-matrix rows for the entry's tier |
| `unsigned_exception` | An `accepted_risk` with no owner or no `review_by` date |

**WARN** (visible, non-gating): `corpus_not_in_manifest`, `orphan_collection`, `missing_collection`,
`model_scope_drift`, `unattributable_traces`.

**note:** accepted risks and pending disclosures — enumerable exceptions are governance working.

## Scheduling & alerting

Weekly cron on jarvis, **Sun 03:30** (offset from `verify-backups.sh` at 03:00), logging to
`/srv/ai-data/backups/ai-bom.log`. Three Prometheus alerts in the `ai-governance` group mirror the
`backup-verify` shape — the finding (`AiBomDriftDetected`), the staleness (`AiBomCheckStale`), and the
**dead-man** (`AiBomMetricsMissing`) — because a governance check that stops running silently is worse
than one that never existed.

## Fixes & gotchas

- **Repo root is resolved by walking up, not by fixed depth.** The script must run from both the git
  repo (`docker/ai/inventory/`) *and* the host tree, where `/opt/homelab` mirrors `docker/` with the
  prefix dropped — a fixed `parents[3]` lands on `/opt` there. On the host, `docs/ai-inventory.yml` +
  `docs/kb-manifest.json` are deployed to `/opt/homelab/ai/inventory/docs/`. Override with `AI_BOM_ROOT`.
- **`/key/list` caps `size` at 100** — LiteLLM returns **422** above it rather than clamping.
- **ClickHouse renders NULL as `\N` in TSV.** Traces with no `user_id` come back as `\N`, not empty;
  both mean the trace carries no system identity. Treating `\N` as a system name manufactures a
  phantom "shadow AI" finding.
- **Textfile-dir writability is checked explicitly.** A present-but-unwritable dir is the dangerous
  case: `absent()` never fires because the stale file is still scraped, so the alert reports old good
  news forever. That exact bug hid a broken backup metric for 9 days (`todos.md` #11).
- **A probe that cannot run returns `None`, never `{}`.** An unreachable LiteLLM must not read as
  "zero keys exist" — that would silently turn a broken check into a passing one.

## Deploying a change

```bash
scp docker/ai/inventory/build-ai-bom.py Jarvis:/tmp/bom.py
scp docs/ai-inventory.yml docs/kb-manifest.json Jarvis:/tmp/
ssh Jarvis 'install -m 0775 -g homelab /tmp/bom.py /opt/homelab/ai/inventory/build-ai-bom.py
  install -m 0664 -g homelab /tmp/ai-inventory.yml /opt/homelab/ai/inventory/docs/ai-inventory.yml
  install -m 0664 -g homelab /tmp/kb-manifest.json /opt/homelab/ai/inventory/docs/kb-manifest.json'
```

Per-file `install` rather than a blanket `chmod -R g+rwX` — the blanket form widens `.env` and
`acme.json` (see `CLAUDE.md`).

## Secrets

- Reads `LITELLM_MASTER_KEY`, `QDRANT_API_KEY`, `N8N_API_KEY` from `/opt/homelab/.env` (override with
  `HOMELAB_ENV`). Read-only; mints nothing.
- **Emits key aliases only, never values.** The BOM is committed and heads for open source.
