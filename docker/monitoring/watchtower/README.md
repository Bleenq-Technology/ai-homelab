# Watchtower
**Purpose:** Automatically pulls and redeploys updated images for opt-in (labelled) containers.
**URL:** internal / no UI
**Auth:** none (internal-only, not exposed via Traefik)
**Image:** containrrr/watchtower:1.7.1
**Networks / data:** `monitoring`; mounts `/var/run/docker.sock`

## Setup as deployed
- Mounts the Docker socket (`/var/run/docker.sock`) to manage containers.
- Command: `--interval=3600` (hourly checks), `--cleanup` (remove old images after update), `--label-enable` (only update containers explicitly labelled for Watchtower).
- `DOCKER_API_VERSION=1.44` is set in the environment.

## Issues & Fixes

**Symptom:** the container exited fatally with `unknown flag: --enable-metrics`.
**Fix:** remove the `--enable-metrics` flag (it does not exist in watchtower 1.7.1).

**Symptom:** after that, watchtower logged `Error response from daemon: client version 1.25 is too old. Minimum supported API version is 1.40`.
**Fix:** set `DOCKER_API_VERSION=1.44` (Docker Engine 29 rejects watchtower's legacy default API version).

## Secrets
- None. Only the non-secret `DOCKER_API_VERSION` env is set.
- Nothing sensitive is committed; real values live in `/opt/homelab/.env` (gitignored).
