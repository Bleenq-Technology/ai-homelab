# LiteLLM
**Purpose:** OpenAI-compatible gateway in front of the local unsloth LLM that logs **every** call to Langfuse — one chokepoint for centralized LLM tracing.
**URL:** https://litellm.pdx.sanctioned.tech (API) — in-cluster: `http://litellm:4000`
**Auth:** LiteLLM **master key** OR a per-app **virtual key** (Bearer). **Not** SSO-gated (it's a programmatic API).
**Image:** `ghcr.io/berriai/litellm:main-stable`
**Networks / data:** `proxy` + `ai` + `data` (Postgres for the virtual-key store); config at [`config.yaml`](config.yaml)

## Setup as deployed
- **Upstreams / models:**
  - `unsloth/Qwen3.5-4B-GGUF` (chat) → unsloth host at `http://192.168.2.10:8888/v1` (key `UNSLOTH_API_KEY`).
  - `bge-m3` (1024-dim embeddings) → the `bge-m3` llama.cpp container at `http://bge-m3:8080/v1`
    (ai-net internal, no auth — see [`../bge-m3/README.md`](../bge-m3/README.md)).
- **Langfuse logging:** `success_callback`/`failure_callback: ["langfuse"]`; `LANGFUSE_PUBLIC_KEY`/`LANGFUSE_SECRET_KEY`
  + `LANGFUSE_HOST=http://langfuse-web:3000` (internal). Verified: calls appear as `litellm-acompletion` traces.
- **Master key:** `LITELLM_MASTER_KEY` — clients send `Authorization: Bearer <key>`.
- **Virtual keys (per-app):** backed by Postgres DB `litellm`
  (`DATABASE_URL=postgresql://litellm:${LITELLM_DB_PASSWORD}@postgres:5432/litellm`; LiteLLM runs
  its Prisma migrations on startup). Mint a scoped key with the master key:
  `POST /key/generate {"key_alias":"<app>","models":["unsloth/Qwen3.5-4B-GGUF"]}` → returns `sk-…`.
  Revoke/rotate per app via `/key/delete` and `/key/generate` without rotating the master key.
  Existing keys: **`apollo`** (Apollo voice-assistant project, 2026-06-17).
- Routed at `litellm.${DOMAIN}` with `secure-chain@file` (master-key auth, **not** SSO). Add a
  `litellm.pdx.sanctioned.tech → 192.168.2.10` EdgeRouter mapping for by-name access.

## Usage
```python
from openai import OpenAI
client = OpenAI(base_url="http://litellm:4000/v1", api_key="<LITELLM_MASTER_KEY>")  # in-cluster
client.chat.completions.create(model="unsloth/Qwen3.5-4B-GGUF",
                               messages=[{"role": "user", "content": "hi"}])
```
Every call is traced in Langfuse. To trace **OpenWebUI** too, set its
`OPENAI_API_BASE_URL=http://litellm:4000/v1` and key = the master key.

## Secrets
- `.env` keys: `LITELLM_MASTER_KEY`, `UNSLOTH_API_KEY`, `LITELLM_DB_PASSWORD`, `LANGFUSE_PUBLIC_KEY`,
  `LANGFUSE_SECRET_KEY`. All in Infisical; nothing committed to git. Per-app virtual keys live in
  the `litellm` Postgres DB (not in `.env`).

## Issues & Fixes
**Symptom:** test call returned `000` right after recreate.
**Fix:** none needed — LiteLLM takes ~20-30 s to start (it initializes the Langfuse callback); the call
succeeds once `Uvicorn running on 0.0.0.0:4000` appears in the logs.
