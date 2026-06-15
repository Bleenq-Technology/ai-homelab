# Open WebUI
**Purpose:** LLM chat frontend for the local unsloth model, with ComfyUI image generation.
**URL:** https://openwebui.pdx.sanctioned.tech
**Auth:** native Keycloak OIDC
**Image:** ghcr.io/open-webui/open-webui:main
**GPU:** no
**Networks / data:** proxy, ai, data; bind mount `./openwebui/data` -> `/app/backend/data`
(the `data` network is for the shared Redis; Qdrant is on `ai`)

## Setup as deployed
- **Config is authoritative from env:** `ENABLE_PERSISTENT_CONFIG=False` — settings come from compose
  on every boot instead of the DB. User accounts/chats are unaffected (that's data, not config).
- LLM backend is the **LiteLLM gateway** (fronts unsloth and traces every call to Langfuse):
  - `ENABLE_OPENAI_API=true`
  - `OPENAI_API_BASE_URL=http://litellm:4000/v1`
  - `OPENAI_API_KEY=${LITELLM_MASTER_KEY}`
  - `ENABLE_OLLAMA_API=false` (Ollama disabled)
- Image generation via ComfyUI on the `ai` network:
  - `ENABLE_IMAGE_GENERATION=true`, `IMAGE_GENERATION_ENGINE=comfyui`, `COMFYUI_BASE_URL=http://comfyui:8188`
- **Web search via Tavily** (LLM/RAG-optimized — returns extracted page content, not just links,
  so grounding is stronger and "no sources" is rare):
  - `ENABLE_WEB_SEARCH=true`, `WEB_SEARCH_ENGINE=tavily`, `TAVILY_API_KEY=${TAVILY_API_KEY}`
  - Self-hosted **SearXNG** stays configured (`SEARXNG_QUERY_URL`) as a fully-private fallback —
    flip `WEB_SEARCH_ENGINE` to `searxng` to use it.
  - `RAG_TEMPLATE` instructs the model to answer **only** from retrieved context and to say it
    could not find reliable sources when search is empty (curbs hallucination on weak results).
- Keycloak SSO (OIDC), merges onto existing accounts by email:
  - `ENABLE_OAUTH_SIGNUP=true`, `OAUTH_MERGE_ACCOUNTS_BY_EMAIL=true`
  - `OAUTH_PROVIDER_NAME=Keycloak`, `OAUTH_CLIENT_ID=openwebui`, `OAUTH_CLIENT_SECRET=${OPENWEBUI_OIDC_CLIENT_SECRET}`
  - `OPENID_PROVIDER_URL=https://keycloak.${DOMAIN}/realms/homelab/.well-known/openid-configuration`
  - `OAUTH_SCOPES=openid email profile`
- **Vector store = shared Qdrant** (replaces the default embedded Chroma), so document/Knowledge
  RAG is persistent and shared, not trapped in `./openwebui/data`:
  - `VECTOR_DB=qdrant`, `QDRANT_URI=http://qdrant:6333`, `QDRANT_API_KEY=${QDRANT_API_KEY}`,
    `QDRANT_COLLECTION_PREFIX=open-webui`
  - Qdrant server pinned to `v1.16.1` to stay within one minor of Open WebUI's bundled 1.17 client
    (a wider gap logs an incompatibility warning).
  - Note: web search **bypasses** retrieval (see above), so Qdrant backs *uploaded docs/Knowledge*.
- **Redis** (shared instance, DB 2) for the websocket manager + app cache:
  - `REDIS_URL` / `WEBSOCKET_REDIS_URL=redis://:${REDIS_PASSWORD}@redis:6379/2`,
    `WEBSOCKET_MANAGER=redis`, `ENABLE_WEBSOCKET_SUPPORT=true`
- Branding: `WEBUI_NAME="Jarvis Open WebUI"`, `WEBUI_URL=https://openwebui.${DOMAIN}`
- Traefik router on `websecure`, TLS, middleware `secure-chain-stream@file`, backend port 8080.

### First login
- Sign in via the Keycloak button. The first user becomes the admin account.

## Model system prompt (reproducibility)
Per-model overrides live in Open WebUI's **own DB** (`./openwebui/data`, SQLite — **not** Postgres,
so not in the `pg_dumpall` backup). The base model `unsloth/Qwen3.5-4B-GGUF` carries a system prompt
so it stops refusing image requests (a separate ComfyUI tool renders images). To re-apply after a
fresh Open WebUI DB:

```bash
TOKEN=$(curl -s -X POST https://openwebui.pdx.sanctioned.tech/api/v1/auths/signin \
  -H 'Content-Type: application/json' -d '{"email":"<you>","password":"<pw>"}' \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')
curl -s -X POST https://openwebui.pdx.sanctioned.tech/api/v1/models/create \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' -d '{
    "id":"unsloth/Qwen3.5-4B-GGUF","base_model_id":null,"name":"Qwen3.5-4B-GGUF",
    "meta":{"capabilities":{"vision":false}},
    "params":{"system":"You are a helpful assistant in an app that has a separate, built-in image-generation tool (powered by ComfyUI). When the user asks for an image, picture, drawing, logo, or any visual, do NOT say you cannot create images - the image tool renders it automatically. Briefly acknowledge and provide a vivid one-sentence visual description suitable as an image prompt. For everything else, answer normally and concisely."},
    "is_active":true}'
```

## Issues & Fixes

**Symptom:** settings set via environment variables did not take effect — Open WebUI persists config in its DB after first boot, and the DB copy wins.
**Fix:** set `ENABLE_PERSISTENT_CONFIG=False` so env config is authoritative on every boot (the DB no longer overrides it); user data is unaffected. (Initially worked around by wiping the data dir to re-seed — the env flag is the clean fix.)

## Secrets
- `LITELLM_MASTER_KEY` — auth for the LiteLLM gateway (the LLM backend).
- `OPENWEBUI_OIDC_CLIENT_SECRET` — Keycloak client secret for the `openwebui` client.
- `TAVILY_API_KEY` — Tavily web-search API key (free tier; in Infisical).
- `QDRANT_API_KEY` — auth for the shared Qdrant vector DB.
- `REDIS_PASSWORD` — auth for the shared Redis (websocket manager + cache).
- `DOMAIN`, `TZ`, optional `HOST_LAN_IP`.
- All secrets come from `/opt/homelab/.env` (gitignored); nothing sensitive is committed.
