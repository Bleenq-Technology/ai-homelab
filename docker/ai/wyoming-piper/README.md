# Wyoming Piper
**Purpose:** Text-to-speech (TTS) over the Wyoming protocol.
**URL:** TCP port 10200 (raw Wyoming protocol — not behind Traefik)
**Auth:** none (LAN/Wyoming protocol)
**Image:** rhasspy/wyoming-piper:2.2.2
**GPU:** yes (NVIDIA reservation, `count: all`)
**Networks / data:** ai; bind mount `./wyoming-piper/data` -> `/data`

## Setup as deployed
- Command: `--voice en_US-lessac-medium`.
- Published as raw TCP `10200:10200` so Wyoming clients (e.g. Home Assistant) can connect
  directly; it speaks the Wyoming TCP protocol, not HTTP, so it is **not routed through Traefik**.
- GPU access via the compose NVIDIA device reservation.
- Voice/model data persists under `./wyoming-piper/data`.

## Issues & Fixes

**Symptom:** The image pull failed because the originally-specified tag did not exist.
**Fix:** use `rhasspy/wyoming-piper:2.2.2`.

## Secrets
- None. `TZ` is inherited from the environment where applicable.
- All secrets come from `/opt/homelab/.env` (gitignored); nothing sensitive is committed.
