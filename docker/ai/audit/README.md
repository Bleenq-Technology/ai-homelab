# AI audit trail

**Purpose:** The long-lived, attributable record of what every AI system did — the evidence that
answers an audit question after Langfuse's traces are gone.
**URL:** none (ClickHouse tables + a nightly export). **Networks / data:** ClickHouse `data` network.

Context: [`docs/ai-governance.md`](../../../docs/ai-governance.md) · backlog: `todos.md` #40.

## Two records, different shapes

| | Langfuse `default.traces` | `ai_governance.gateway_calls` |
|---|---|---|
| Contents | **Full** prompt + response bodies | **No bodies** — SHA-256 hashes only |
| Retention | **14 days** | **13 months** |
| For | Debugging | Traceability / audit |

Langfuse's 14-day TTL is the right call for debugging — `todos.md` #25 found ClickHouse's logs at
5.65 GiB, and the ruling was "traces are only interesting for about a week." It's the **wrong** call
for traceability: if a public surface says something harmful, a key leaks, or someone asks *"what did
your system tell me in June"*, 14 days of evidence is nothing.

The fix isn't a longer TTL — that re-creates the 5.65 GiB problem and re-inflates the nightly backup.
It's **fat + short** alongside **slim + long**. At **292 KiB** for ~3,800 calls, a year of the slim
record costs nothing.

## Attribution — the prerequisite

Before 2026-07-22 every trace arrived with `user_id` NULL, empty metadata, and one `User-Agent: n8n`
tag. **Nothing was attributable to a system** — fatal, because four different systems share the n8n
container (KB flows, content-curator, and both public chat surfaces), so User-Agent tells you nothing.

Fixed in [`../litellm/config.yaml`](../litellm/config.yaml):

```yaml
litellm_settings:
  langfuse_default_tags: [user_api_key_alias, ...]
```

`user_api_key_alias` is the **virtual key alias**, which is exactly the system name in
[`ai-inventory.yml`](../../../docs/ai-inventory.yml) — so traces join directly to the AI-BOM.

## Running it

```bash
/opt/homelab/ai/audit/export-audit.sh --publish 3     # daily cron, 02:30
/opt/homelab/ai/audit/export-audit.sh 14              # wider backfill
```

Daily → `/srv/ai-data/backups/ai-audit.log`. **Daily, not weekly** — the source is destroyed by a
14-day TTL, so a gap becomes a permanent hole. Three alerts (`ai-audit` group): staleness at 36h,
**dead-man at `critical`** (the loss is irreversible, which is what earns the tier), and
`AiAuditUnattributedCalls`.

Useful view: `SELECT * FROM ai_governance.daily_by_system`.

Backed up nightly — `backup.sh` runs `BACKUP ALL EXCEPT DATABASES system, information_schema, scanner`,
so `ai_governance` is included automatically. Verify it stays that way if that exclude list changes.

## Design notes & gotchas

- **The export runs entirely inside ClickHouse** as one `INSERT … SELECT`. Bodies are hashed in place
  and never cross the shell boundary, so the script cannot leak the text it summarises.
- **Idempotent:** `ReplacingMergeTree ORDER BY (trace_id)`. Re-running an overlapping window replaces
  rather than duplicates — which is what makes a generous lookback safe. Missing a day is
  unrecoverable; double-counting one costs nothing.
- **`arrayFirst` returns an empty string, not NULL,** when no tag matches. `nullIf(…,'None')` alone
  lets `''` through, so rows land with a **blank** system instead of `'unattributed'` — silently
  hiding the exact population the column exists to surface. Both sentinels must be mapped.
- **Aggregate observations per trace before joining,** or a multi-observation trace fans out into
  duplicate audit rows with different token counts.
- **Alert on *recent* unattributed calls, not the total.** The total is dominated by history and
  shrinks on its own as the source TTL rolls forward, so an alert on it would resolve itself without
  anyone fixing anything.
- **Separate database, not a table in `default`.** Langfuse owns `default` and migrates it; anything
  of ours in there is one upgrade away from being dropped.
- `token` counts are frequently **0** — the local llama.cpp upstream doesn't always report usage.
  Don't build billing on this column; it's for shape, not accounting.

## Known gap

**Nothing prevents deletion.** `todos.md` #40 asked that no runtime role be able to `DELETE` from the
audit record (mirroring the `exampleapp_delivery` REVOKE pattern). ClickHouse access here is a single
admin user, so that is **not enforced today** — it needs a restricted ClickHouse role, which is its own
change. Recorded rather than quietly skipped.

## Secrets

None. The table holds hashes, not content.
