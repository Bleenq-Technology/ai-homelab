# ComfyUI
**Purpose:** Image generation backend (consumed by Open WebUI).
**URL:** https://comfyui.pdx.sanctioned.tech
**Auth:** Keycloak forward-auth (Traefik middleware)
**Image:** ghcr.io/ai-dock/comfyui:latest
**GPU:** yes (NVIDIA reservation, `count: all`)
**Networks / data:** proxy, ai; bind mount `./comfyui/data` -> `/data`

## Setup as deployed
- GPU access via the compose `deploy.resources.reservations.devices` NVIDIA reservation.
- Models and workflows persist under `./comfyui/data`.
- Reached internally by Open WebUI at `http://comfyui:8188` on the `ai` network.
- Traefik router on `websecure`, TLS, middlewares `sso@file,secure-chain-stream@file`,
  backend port 8188.

### First use
- A model/workflow must be loaded before generation works. Place models under the bind mount
  (`./comfyui/data`) and load a workflow in the UI.

## Fixes & gotchas
- **Community image, not official**: there is no official ComfyUI image. `ghcr.io/ai-dock/comfyui`
  is a popular community build — confirm it and pin to a specific tag/digest before production
  deploy rather than tracking `:latest`.
- Image generation will fail from Open WebUI until a model/workflow is loaded here.

## Secrets
- None specific to this service (auth is handled by the Keycloak forward-auth middleware).
- `TZ` only. All secrets come from `/opt/homelab/.env` (gitignored); nothing sensitive is committed.
