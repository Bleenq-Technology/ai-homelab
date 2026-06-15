# LiteLLM
**Purpose:** OpenAI-compatible gateway in front of the local unsloth LLM that logs **every** call to Langfuse — one chokepoint for centralized LLM tracing.
**URL:** https://litellm.pdx.sanctioned.tech (API) — in-cluster: `http://litellm:4000`
**Auth:** LiteLLM **master key** (Bearer). **Not** SSO-gated (it's a programmatic API).
**Image:** `ghcr.io/berriai/litellm:main-stable`
**Networks / data:** `proxy` + `ai`; config at [`config.yaml`](config.yaml)

## Setup as deployed
- **Upstream:** unsloth at `http://192.168.2.10:8888/v1` (key `UNSLOTH_API_KEY`); model alias `unsloth/Qwen3.5-4B-GGUF`.
- **Langfuse logging:** `success_callback`/`failure_callback: ["langfuse"]`; `LANGFUSE_PUBLIC_KEY`/`LANGFUSE_SECRET_KEY`
  + `LANGFUSE_HOST=http://langfuse-web:3000` (internal). Verified: calls appear as `litellm-acompletion` traces.
- **Master key:** `LITELLM_MASTER_KEY` — clients send `Authorization: Bearer <key>`.
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
- `.env` keys: `LITELLM_MASTER_KEY`, `UNSLOTH_API_KEY`, `LANGFUSE_PUBLIC_KEY`, `LANGFUSE_SECRET_KEY`.
  All in Infisical; nothing committed to git.

## Issues & Fixes
**Symptom:** test call returned `000` right after recreate.
**Fix:** none needed — LiteLLM takes ~20-30 s to start (it initializes the Langfuse callback); the call
succeeds once `Uvicorn running on 0.0.0.0:4000` appears in the logs.
