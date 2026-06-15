# ComfyUI
**Purpose:** Image generation backend (consumed by Open WebUI).
**URL:** https://comfyui.pdx.sanctioned.tech
**Auth:** Keycloak forward-auth (Traefik middleware)
**Image:** ghcr.io/ai-dock/comfyui:latest
**GPU:** yes (NVIDIA reservation, `count: all`)
**Networks / data:** proxy, ai; bind mount `./comfyui/data` -> `/data`; named volume
`comfyui_storage` -> `/opt/storage` (the ai-dock model store — checkpoints/loras/vae)

## Setup as deployed
- GPU access via the compose `deploy.resources.reservations.devices` NVIDIA reservation.
- `WEB_ENABLE_AUTH=false` — disables the ai-dock caddy login portal so `:8188` serves the raw
  ComfyUI API (the Traefik route is still Keycloak-gated; Open WebUI reaches it on the `ai` network).
- **Model store** = named volume `comfyui_storage` at `/opt/storage` (ai-dock symlinks
  `/opt/ComfyUI/models/*` there). **SDXL base** (`sd_xl_base_1.0.safetensors`) is installed under
  `/opt/storage/stable_diffusion/models/ckpt/`.
- Open WebUI drives it at `http://comfyui:8188`; the SDXL txt2img workflow + node mapping live in
  Open WebUI's env (`COMFYUI_WORKFLOW` / `COMFYUI_WORKFLOW_NODES`), with `IMAGE_GENERATION_MODEL`,
  `IMAGE_SIZE`, `IMAGE_STEPS`.
- Traefik router on `websecure`, TLS, middlewares `sso@file,secure-chain-stream@file`, port 8188.

### Adding models
```
docker exec comfyui sh -c "wget -O /opt/storage/stable_diffusion/models/ckpt/<model>.safetensors <url>"
docker compose -f compose.yml restart comfyui     # ComfyUI rescans on restart
```

## Issues & Fixes

**Symptom:** Open WebUI image generation did nothing; calls to `comfyui:8188` returned `302 -> /login`, and the raw ComfyUI API was on `127.0.0.1:18188` (localhost-only, unreachable from other containers).
**Fix:** the ai-dock image gates ComfyUI behind a caddy login portal on `:8188`. Set `WEB_ENABLE_AUTH=false` so `:8188` proxies straight to the ComfyUI API.

**Symptom:** downloaded models vanished on container recreate.
**Fix:** the ai-dock store is `/opt/storage`, not the `/data` bind mount. Persist it with the `comfyui_storage` named volume (Docker seeds it from the image's dir structure).

**Symptom:** generation failed — no model.
**Fix:** the image ships empty; install a checkpoint (SDXL base here). Note `ghcr.io/ai-dock/comfyui` is a community image (no official one) — pin a digest for production.

## Secrets
- None specific to this service (auth is handled by the Keycloak forward-auth middleware).
- `TZ` only. All secrets come from `/opt/homelab/.env` (gitignored); nothing sensitive is committed.
