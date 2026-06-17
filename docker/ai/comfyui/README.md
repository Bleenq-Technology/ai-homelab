# ComfyUI
**Purpose:** Image generation backend (consumed by Open WebUI).
**URL:** https://comfyui.pdx.sanctioned.tech
**Auth:** Keycloak SSO via Traefik (`sso@file,secure-chain-stream@file`); the container itself
has **no built-in auth** — reachable unauthenticated on the `ai` network (Open WebUI uses that).
**Image:** `mmartial/comfyui-nvidia-docker:ubuntu24_cuda13.0-20260605` (pinned; maintained, replaced
the unmaintained `ghcr.io/ai-dock/comfyui`).
**GPU:** yes (NVIDIA reservation, `count: all`).
**Networks / data:** `proxy`, `ai`. Two bind mounts: `./comfyui/run` → `/comfy/mnt` (the Python
venv + runtime) and `./comfyui/basedir` → `/basedir` (models + outputs, kept separate from the venv).

## Setup as deployed
- GPU access via the compose `deploy.resources.reservations.devices` NVIDIA reservation.
- **Runs as the deploy user** for clean file perms: `WANTED_UID=1001` / `WANTED_GID=1001`.
- **`BASE_DIRECTORY=/basedir`** separates models/outputs from the venv/run dir. The image serves the
  raw ComfyUI API on `:8188` directly (no login portal), so the Traefik route is the only gate.
- **`COMFY_CMDLINE_EXTRA=--disable-smart-memory`** — avoids ComfyUI holding the model in VRAM, so the
  shared RTX 3090 isn't starved (unsloth on the host + other AI services share it).
- **Model store** lives under the `basedir` bind mount: checkpoints in
  `./comfyui/basedir/models/checkpoints/`. **SDXL base** (`sd_xl_base_1.0.safetensors`) is installed there.
- Open WebUI drives it at `http://comfyui:8188`; the SDXL txt2img workflow + node mapping live in Open
  WebUI's env (`COMFYUI_WORKFLOW` / `COMFYUI_WORKFLOW_NODES`), with `IMAGE_GENERATION_MODEL`,
  `IMAGE_SIZE`, `IMAGE_STEPS`.
- Traefik router on `websecure`, TLS, middlewares `sso@file,secure-chain-stream@file` (the streaming
  chain skips rate-limiting so long generations/websockets aren't throttled), backend port 8188.

### Adding models
The `basedir` is a host bind mount, so just drop files in and ComfyUI rescans on restart:
```
# place a checkpoint on the host:
#   /opt/homelab/ai/comfyui/basedir/models/checkpoints/<model>.safetensors
docker compose -f compose.yml restart comfyui
```

## Notes
- The old ai-dock image gated ComfyUI behind a caddy login portal and used `/opt/storage` as the
  model store; the mmartial image does neither — models live under `/basedir`, and there's no
  `WEB_ENABLE_AUTH`. The old `comfyui_storage` named volume was retired (kept briefly for rollback).
- No official ComfyUI image exists; `mmartial/comfyui-nvidia-docker` is the maintained community build
  — pinned to a dated tag here.

## Secrets
- None specific to this service (auth is handled by the Traefik SSO middleware).
- `TZ` only. All secrets come from `/opt/homelab/.env` (gitignored); nothing sensitive is committed.
