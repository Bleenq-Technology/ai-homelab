# n8n workflows — `kb_homelab_docs` KB

Native-node n8n workflows that build and serve the **`kb_homelab_docs`** knowledge base
(Qdrant collection, `bge-m3` 1024-dim / Cosine — see [`docs/kb-standards.md`](../../../../docs/kb-standards.md)).
Exported with **no secrets** — only credential *references* (id + name). Import, then attach the
three credentials below by name.

## Workflows

| File | Purpose |
|------|---------|
| `kb_homelab_docs-ingest.json` | **Schedule (daily 04:00) + Manual** → clear collection → **Qdrant Vector Store [insert]** fed by **GitHub Document Loader** (+ Recursive Character Text Splitter) and **bge-m3 Embeddings**. Clears + rebuilds the collection each run. |
| `kb_homelab_docs-chat.json` | **Chat Trigger** (public hosted chat) → **AI Agent** with **OpenAI Chat Model** (`unsloth/Qwen3.5-4B-GGUF` via LiteLLM), **Window Buffer Memory**, and **Qdrant [retrieve-as-tool]** (`homelab_docs`, its own bge-m3 embeddings). |

**Ingest source:** GitHub repo `Bleenq-Technology/ai-homelab-infra` @ `main`. The GitHub Document
Loader has no include-glob, so **markdown-only** is achieved via `additionalOptions.ignorePaths`
(globs excluding every non-`.md` extension). Adjust that list if new doc extensions are added.

**Clear + rebuild:** native vector-store *insert* appends (random point ids, no hash dedup), so the
flow first `DELETE`s the Qdrant collection (HTTP Request node using the **Qdrant** credential), then
the insert auto-recreates it at 1024/Cosine.

## Required credentials (create in n8n → Credentials; values from Infisical / jarvis `.env`)

| Name | Type | Config |
|------|------|--------|
| `KB GitHub (ai-homelab-infra RO)` | GitHub API | server `https://api.github.com`; access token = `GITHUB_PAT` (fine-grained, org `Bleenq-Technology`, Contents:read) |
| `LiteLLM (OpenAI-compat)` | OpenAI API | Base URL `http://litellm:4000/v1`; API key = `LITELLM_MASTER_KEY` |
| `Qdrant (homelab)` | Qdrant API | URL `http://qdrant:6333`; API key = `QDRANT_API_KEY` |

## Use

- **Chat:** the chat workflow is `public: true` — hosted chat at
  `https://n8n.pdx.sanctioned.tech/webhook/kb-homelab-docs-chat/chat`
  (POST `{ "action":"sendMessage", "sessionId":"...", "chatInput":"..." }`).
- **Manual ingest run (headless, on jarvis):** the n8n CLI shares the running container's network
  namespace, so move its task-broker off the in-use port:
  ```bash
  docker exec -e N8N_RUNNERS_BROKER_PORT=5699 -e N8N_RUNNERS_BROKER_LISTEN_ADDRESS=127.0.0.1 \
    n8n n8n execute --id <ingest-workflow-id>
  ```
