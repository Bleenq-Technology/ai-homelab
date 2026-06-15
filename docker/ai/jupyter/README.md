# Jupyter
**Purpose:** JupyterLab notebooks.
**URL:** https://jupyter.pdx.sanctioned.tech
**Auth:** token (printed in container logs)
**Image:** jupyter/base-notebook:latest
**GPU:** no
**Networks / data:** proxy, ai; bind mount `./jupyter/data` -> `/home/jovyan/work`

## Setup as deployed
- Lab mode enabled: `JUPYTER_ENABLE_LAB=yes`, `DOCKER_STACKS_JUPYTER_CMD=lab`.
- Notebooks persist under `./jupyter/data` (`/home/jovyan/work`).
- Traefik router on `websecure`, TLS, middleware `secure-chain-stream@file`, backend port 8888.

### First login
- The access **token** is generated at startup and printed in the container logs:
  ```
  docker logs jupyter
  ```
  Use that token (or the tokenized URL) to log in.

## Fixes & gotchas
- No service-specific fixes. Auth is the default Jupyter token; retrieve it from the logs after
  each restart (token changes on restart unless a fixed token/password is configured).

## Secrets
- None in `.env` (token is runtime-generated). `TZ` only.
- All secrets come from `/opt/homelab/.env` (gitignored); nothing sensitive is committed.
