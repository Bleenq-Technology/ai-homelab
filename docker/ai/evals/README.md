# Governance evals

**Purpose:** Assert that the platform's guardrails still hold. A guardrail with no regression test
decays — this is what stops a workflow or config edit from silently removing one.
**URL:** none (a script). **Networks / data:** runs on the jarvis host against the live gateway + n8n.

Context: [`docs/ai-governance.md`](../../../docs/ai-governance.md) · backlog: `todos.md` #42.

## Why

`CLAUDE.md` documents that changing the shared model ripples through the LiteLLM config,
`kb-manifest.json`, regenerated n8n workflows, per-app key scopes, the OpenWebUI model row, and **two
sibling repos** — and the verification for all of it was *"run it and see."* We hold a hard bar on
infra (*prove a change works*) and had **no bar at all on AI behaviour**.

## Two severities, and the distinction is the design

| | Meaning | On failure |
|---|---|---|
| `blocking: true` | A **security or isolation** property that must always hold | Exit 1 + `critical` alert |
| `blocking: false` | A **quality** property (retrieval relevance) | Reported only, never gates |

**A gate that is usually red gets disabled.** Only properties that must hold are allowed to fail the
run; retrieval quality drifts for benign reasons (re-ingest, chunking) and is advisory.

## Running it

```bash
/opt/homelab/ai/evals/run-evals.py              # everything
/opt/homelab/ai/evals/run-evals.py --publish    # + Prometheus metrics (daily cron, 03:10)
/opt/homelab/ai/evals/run-evals.py --blocking-only
```

**Run it before committing anything under `docker/ai/**` or an n8n workflow change.** It takes ~2s.

**It is NOT in CI, deliberately.** The suite must hit the live gateway and the live workflows, and CI
cannot reach jarvis's internal networks. A CI job that mocked them would assert nothing. Daily on the
host + run-before-you-commit is the honest arrangement; the *static* AI-BOM check is the part that
does gate PRs.

## What it asserts

Every case is derived from a probe actually run against the live platform, not invented:

- **`key-scope-enforced`** — the embeddings-only `research` key cannot reach a chat model.
- **`graph-search-requires-auth`** — the text2cypher webhook rejects unauthenticated callers (it
  didn't, until 2026-07-22).
- **`graph-search-refuses-write-cypher`** — asked to delete the graph, the model *does* emit
  `MATCH (n) DETACH DELETE n`; the guard must refuse it.
- **`graph-search-caps-limit`** — `LIMIT` is capped, not merely supplied.
- **`playbook-cannot-reach-web-app-corpus`** — `todos.md` #28's isolation requirement.
- **`embeddings-are-1024-dim`** — the KB interoperability standard.
- **`gateway-chat-well-formed`** — the gateway returns a usable completion.
- Advisory: KB retrieval finds a known answer; `kb-list` serves the registry.

## Design notes & gotchas

- **Assertion-based, not LLM-judged.** Every case is checkable with a status code, substring, regex,
  or vector length. A property that can't be checked deterministically doesn't belong in the blocking
  set.
- **Assert on citations, not on prose.** The isolation case originally checked that the answer
  contained no out-of-scope words — and **failed on a correctly isolated bot**, because a good answer
  restates the question ("the context does not contain information about the Homelab **jarvis**
  server..."). That's a bad test, not a broken system. It now asserts that no `example.com` URL appears
  in the **sources**, which is the structural signal for which collection was retrieved from.
  *Relaxing an assertion to make it green would have been worse than deleting the case.*
- **A probe that can't run is a FAIL, never a pass.** A missing key or unreachable host returns
  status 0 and fails loudly, so a broken harness can't masquerade as a passing suite.
- **`expect_status` accepts a range** (`401-403`): LiteLLM answers 401 for a bad key and 403 for an
  out-of-scope model, and which one applies isn't the property under test.
- **The suite has its own `evals` virtual key**, minted from the inventory like any other system, so
  test traffic is separately attributable in the audit record and separately budgeted. Test traffic
  must never be mistaken for a real system's usage.

**The gate is negative-tested:** temporarily widening the `research` key to include a chat model
made `key-scope-enforced` fail; restoring the scope made it pass.

## Secrets

Reads keys from `/opt/homelab/.env` (`EVALS_LLM_KEY`, the BFF tokens, `RESEARCH_LLM_KEY`).
No secret values in `cases.yml` — cases reference **env var names**, never values.
