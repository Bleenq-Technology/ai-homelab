# n8n workflows — Bleenq KB library

Manifest-driven n8n workflows that build and serve the shared **`kb_*`** knowledge bases
(Qdrant, `bge-m3` 1024-dim / Cosine — see [`docs/kb-standards.md`](../../../../docs/kb-standards.md)).

**Single source of truth:** [`docs/kb-manifest.json`](../../../../docs/kb-manifest.json) — the list of KBs
(name, description, collection, source repo, include filter, enabled flag). Both workflows below are
**generated** from it by [`../build_kb_workflows.py`](../build_kb_workflows.py). Exported JSON carries
only credential *id+name* references — **no secrets**.

> **Add / change a KB:** edit `docs/kb-manifest.json` → `python3 docker/ai/n8n/build_kb_workflows.py`
> → re-deploy the two JSONs via the n8n API (PUT existing, or delete+create). Then run `kb-ingest` once
> to populate the new collection.

## Workflows

| File | Purpose |
|------|---------|
| `kb-ingest.json` | **Schedule (daily 04:00) + Manual** → one *clear collection → Qdrant insert* chain per enabled KB, each fed by a **GitHub Document Loader** (markdown-only via `ignorePaths`) + Recursive Char Text Splitter + **bge-m3 Embeddings**. Clears + rebuilds every collection each run. |
| `kb-chat.json` | **Chat Trigger** (public hosted chat, path `bleenq-kb-chat`) → **AI Agent** with **one Qdrant retrieve-as-tool per KB** + **OpenAI Chat Model** (`unsloth/Qwen3.5-4B-GGUF` via LiteLLM) + Window Buffer Memory. The KB catalog is baked into the agent's system prompt, so it can **enumerate the KBs** and **route** each question to the right collection(s) (and synthesise across them). |
| `kb-search.json` | **Shared access layer** (kb-standards §5): `POST /webhook/kb-search {collection, query, topK}` → embed (`bge-m3`) → Qdrant search → `{results, collection, query}`. Reusable by any app/agent. |
| `kb-list.json` | `GET /webhook/kb-list` → the live `kb-manifest.json` registry. |

> **Access-layer contract + examples:** [`docs/kb-access-layer.md`](../../../../docs/kb-access-layer.md).

**Routing is the agent's job:** each KB is a retrieval tool whose description comes from the manifest;
the LLM picks the relevant tool(s). Verified — a trading question calls only `Search kb_trading_docs`,
a homelab question only `Search kb_homelab_docs`, and "what KBs do you have?" answers from the catalog
with no retrieval.

## Required credentials (create in n8n → Credentials; values from Infisical / jarvis `.env`)

| Name | Type | Config |
|------|------|--------|
| `KB GitHub (ai-homelab-infra RO)` | GitHub API | server `https://api.github.com`; token = `GITHUB_PAT` (fine-grained, org `Bleenq-Technology`, **all repos**, Contents:read) |
| `LiteLLM (OpenAI-compat)` | OpenAI API | Base URL `http://litellm:4000/v1`; API key = `LITELLM_MASTER_KEY` |
| `Qdrant (homelab)` | Qdrant API | URL `http://qdrant:6333`; API key = `QDRANT_API_KEY` |

## Use

- **Chat:** hosted chat at `https://n8n.pdx.sanctioned.tech/webhook/bleenq-kb-chat/chat`
  (POST `{ "action":"sendMessage", "sessionId":"...", "chatInput":"..." }`). Surfaced in OpenWebUI as
  the **"KB: Bleenq Knowledge"** model — see [`../../openwebui/functions/`](../../openwebui/functions/).
- **Manual ingest run (headless, on jarvis):** the n8n CLI shares the running container's network
  namespace, so move its task-broker off the in-use port:
  ```bash
  docker exec -e N8N_RUNNERS_BROKER_PORT=5699 -e N8N_RUNNERS_BROKER_LISTEN_ADDRESS=127.0.0.1 \
    n8n n8n execute --id <kb-ingest-workflow-id>
  ```

## Notes / caveats

- **Clear + rebuild** (not incremental): the native vector-store insert appends with random point ids,
  so each run deletes + recreates every collection. Fine for these small markdown repos; switch to §4
  content-hash upsert if a source grows large.
- **Markdown-only** is approximated by excluding every non-`.md` extension via `ignorePaths` (the GitHub
  loader has no include filter). The exclude list lives in the generator.
