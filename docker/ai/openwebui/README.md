# Open WebUI
**Purpose:** LLM chat frontend for the local unsloth model, with ComfyUI image generation.
**URL:** https://openwebui.pdx.sanctioned.tech
**Auth:** native Keycloak OIDC
**Image:** ghcr.io/open-webui/open-webui:main
**GPU:** no
**Networks / data:** proxy, ai; bind mount `./openwebui/data` -> `/app/backend/data`

## Setup as deployed
- LLM backend is the local **unsloth** server (llama.cpp, OpenAI-compatible) running on the host:
  - `ENABLE_OPENAI_API=true`
  - `OPENAI_API_BASE_URL=http://192.168.2.10:8888/v1` (host LAN IP, via `HOST_LAN_IP` with that default)
  - `OPENAI_API_KEY=${UNSLOTH_API_KEY}`
  - `ENABLE_OLLAMA_API=false` (Ollama disabled; unsloth only)
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

**Symptom:** The unsloth / ComfyUI / OIDC settings set via environment variables did not take effect, because Open WebUI persists configuration in its database after first boot.
**Fix:** wipe the data directory once and recreate the container so the settings re-seed from the environment (safe only because no user accounts existed yet).

## Secrets
- `UNSLOTH_API_KEY` — API key for the local unsloth LLM server.
- `OPENWEBUI_OIDC_CLIENT_SECRET` — Keycloak client secret for the `openwebui` client.
- `DOMAIN`, `TZ`, optional `HOST_LAN_IP`.
- All secrets come from `/opt/homelab/.env` (gitignored); nothing sensitive is committed.
