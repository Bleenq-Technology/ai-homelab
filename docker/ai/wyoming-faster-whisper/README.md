# Wyoming Faster-Whisper
**Purpose:** Speech-to-text (STT) over the Wyoming protocol.
**URL:** TCP port 10300 (raw Wyoming protocol — not behind Traefik)
**Auth:** none (LAN/Wyoming protocol)
**Image:** rhasspy/wyoming-whisper:3.2.0
**GPU:** yes (NVIDIA reservation, `count: all`)
**Networks / data:** ai; bind mount `./wyoming-faster-whisper/data` -> `/data`

## Setup as deployed
- Command: `--model base --language en`.
- Published as raw TCP `10300:10300` for Wyoming clients (e.g. Home Assistant); Wyoming TCP
  protocol, not HTTP, so **not routed through Traefik**.
- GPU access via the compose NVIDIA device reservation.
- Model data persists under `./wyoming-faster-whisper/data`.

## Issues & Fixes

**Symptom:** The image pull failed with `pull access denied for rhasspy/wyoming-faster-whisper, repository does not exist or may require 'docker login'`.
**Fix:** the correct image is `rhasspy/wyoming-whisper:3.2.0` (the repository is `wyoming-whisper`, not `wyoming-faster-whisper`).

## Secrets
- None. All secrets come from `/opt/homelab/.env` (gitignored); nothing sensitive is committed.
