# Open WebUI
**Purpose:** LLM chat frontend for the local unsloth model, with ComfyUI image generation.
**URL:** https://openwebui.pdx.sanctioned.tech
**Auth:** native Keycloak OIDC
**Image:** ghcr.io/open-webui/open-webui:main
**GPU:** no
**Networks / data:** proxy, ai; bind mount `./openwebui/data` -> `/app/backend/data`

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
- Keycloak SSO (OIDC), merges onto existing accounts by email:
  - `ENABLE_OAUTH_SIGNUP=true`, `OAUTH_MERGE_ACCOUNTS_BY_EMAIL=true`
  - `OAUTH_PROVIDER_NAME=Keycloak`, `OAUTH_CLIENT_ID=openwebui`, `OAUTH_CLIENT_SECRET=${OPENWEBUI_OIDC_CLIENT_SECRET}`
  - `OPENID_PROVIDER_URL=https://keycloak.${DOMAIN}/realms/homelab/.well-known/openid-configuration`
  - `OAUTH_SCOPES=openid email profile`
- Branding: `WEBUI_NAME="Jarvis Open WebUI"`, `WEBUI_URL=https://openwebui.${DOMAIN}`
- Traefik router on `websecure`, TLS, middleware `secure-chain-stream@file`, backend port 8080.

### First login
- Sign in via the Keycloak button. The first user becomes the admin account.

## Issues & Fixes

**Symptom:** settings set via environment variables did not take effect — Open WebUI persists config in its DB after first boot, and the DB copy wins.
**Fix:** set `ENABLE_PERSISTENT_CONFIG=False` so env config is authoritative on every boot (the DB no longer overrides it); user data is unaffected. (Initially worked around by wiping the data dir to re-seed — the env flag is the clean fix.)

## Secrets
- `LITELLM_MASTER_KEY` — auth for the LiteLLM gateway (the LLM backend).
- `OPENWEBUI_OIDC_CLIENT_SECRET` — Keycloak client secret for the `openwebui` client.
- `DOMAIN`, `TZ`, optional `HOST_LAN_IP`.
- All secrets come from `/opt/homelab/.env` (gitignored); nothing sensitive is committed.
