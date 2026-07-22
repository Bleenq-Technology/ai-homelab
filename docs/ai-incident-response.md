# AI incident response

**Short on purpose.** We have a mature incident path for **infra** failures (Alertmanager → Discord,
dead-man alerts, restore-verified backups) and had **none** for AI failure classes — those were noticed
by a human happening to read a chat log. This is that path.

**Owner:** Paul Vilevac · **Last reviewed:** 2026-07-22 · Context:
[`ai-governance.md`](ai-governance.md) · [`ai-inventory.yml`](ai-inventory.yml)

---

## The kill-switch (read this first)

**Revoking a system's virtual key cuts it off immediately.** That is the single most useful action in
almost every scenario below, it is reversible (mint a new one), and it is **tested**:

```bash
cd /opt/homelab && MK=$(grep -E '^LITELLM_MASTER_KEY=' .env | cut -d= -f2-)
# find the key's token (the hash, not the secret)
curl -s -H "Authorization: Bearer $MK" \
  "https://litellm.lab.example/key/list?return_full_object=true&size=100" \
  | python3 -c "import sys,json;[print(k['key_alias'],k['token']) for k in json.load(sys.stdin)['keys'] if k.get('key_alias')]"
# revoke
curl -s -X POST -H "Authorization: Bearer $MK" -H 'Content-Type: application/json' \
  -d '{"keys":["<token>"]}' https://litellm.lab.example/key/delete
```

**Verified 2026-07-22:** `/key/delete` → 200, and the very next call with that key → **401**. An
untested kill-switch is a belief, so this was exercised end-to-end on a throwaway key.

**Blast radius per system** is the `credential.alias` in [`ai-inventory.yml`](ai-inventory.yml).
Revoking `web-app` stops the public example.com chat and nothing else; revoking `n8n-kb` stops the KB
flows. **Never revoke the master key** — it is the administrative credential you need to fix everything
else.

**Wider switches, in escalating order:**

| Scope | Action |
|---|---|
| One system | `/key/delete` its alias (above) |
| One public surface | Stop its BFF/tunnel container — the site stays up, the chat stops |
| One workflow | Deactivate it in n8n (Settings → Active off) |
| All AI | `docker compose -f compose.yml stop litellm` — every system loses model access at once |
| The host LLM | `sudo systemctl stop unsloth-studio` |

---

## Failure classes

| Class | What it looks like | Detection today | First response |
|---|---|---|---|
| **Harmful / wrong output on a public surface** | A screenshot, a complaint, an odd answer | ⚠️ **Human report only** — no automated content check | Revoke that surface's key → pull its Langfuse traces → keep evidence (below) |
| **Prompt injection succeeded** | A tool call or query the user shouldn't have been able to cause | `[graph-guard] REFUSED` lines in Loki show attempts; a *success* shows as an unexpected allowed query | Revoke the key; read the generated statements; tighten the guard; add an eval case |
| **Key leaked / abused** | Rate-limit alerts, unexpected spend or volume | `AiEvalBlockingFailure`, LiteLLM limits, `daily_by_system` | Revoke → mint a new one → `push-secret.sh` → `pull-secrets.sh` → recreate the consumer |
| **Corpus poisoned** | Answers citing content nobody added | ⚠️ Weak — no ingest content check | `delete-by-source.py` the bad source; re-ingest; check what else that run added |
| **Model / quality regression** | Answers degrade after a change | `AiEvalBlockingFailure` (security cases), advisory cases for quality | Re-run `run-evals.py`; roll back the change; `verify-models.sh` for weight integrity |
| **Shadow AI** | A system calling a model outside the gateway | `AiBomDriftDetected` (unregistered credential/trace), `check-egress.sh` | Identify the caller; register it or stop it |
| **Governance control stopped running** | Silence where there should be checks | The **dead-man** alerts (`*MetricsMissing`) | Treat as an incident: "we don't know" is worse than a known failure |

---

## Evidence to preserve (do this BEFORE remediating)

Langfuse deletes full prompt/response bodies after **14 days**. Once gone they cannot be recovered —
the long-lived record keeps **hashes only**. So for anything that might matter later:

```bash
# full traces for one system, last 3 days — capture BEFORE the TTL passes
docker exec clickhouse clickhouse-client -q "
  SELECT timestamp, tags, input, output FROM default.traces
  WHERE timestamp > now() - INTERVAL 3 DAY
    AND has(tags, 'user_api_key_alias:<alias>')
  ORDER BY timestamp FORMAT JSONEachRow" > /srv/ai-data/backups/incident-<date>.json
```

The slim record (`ai_governance.gateway_calls`, 13 months) gives you who/when/model/tokens and content
**hashes** — enough to prove *whether* a specific text was produced, never enough to reproduce it.

---

## Where a human is in the loop

Per-system, in [`ai-inventory.yml`](ai-inventory.yml) (`human_oversight`). Honest summary:

- **T1** (OpenWebUI, Assistant, evals) — a human reads every output before it matters.
- **T2** (both public chats, `n8n-kb`, `content-curator`, `home-assistant`, `research-app`) —
  **no human per action**. Oversight is after-the-fact via traces. ⚠️ **Periodic review of public chat
  transcripts is not yet a scheduled commitment** — that remains open.
- **T3** (`example-app`) — the execution gate requires human approval; the protection monitor pages
  rather than acts.

---

## After any incident

1. **Add an eval case** ([`docker/ai/evals/cases.yml`](../docker/ai/evals/cases.yml)) so the same
   failure cannot recur silently. This is the step that compounds — #41's guardrails exist because a
   defect was found, and they stay honest because cases assert them daily.
2. Update the affected system's `ai-inventory.yml` entry (tier, oversight, `accepted_risk`).
3. If a control was missing rather than broken, file it in `todos.md` — don't leave it in a commit
   message.
