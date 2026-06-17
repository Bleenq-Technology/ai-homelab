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

## Custom / extra voices

Voices are **not** committed to git (large ONNX binaries). They live on the jarvis
host under `/opt/homelab/ai/wyoming-piper/data/` (the `./wyoming-piper/data` bind mount),
alongside the auto-downloaded default `en_US-lessac-medium`.

**How wyoming-piper loads a custom voice (image 2.2.2, verified 2026-06-17):**
1. Drop **both** files into the data dir: `<name>.onnx` and `<name>.onnx.json`.
2. The name **must** be in BCP-47 form `en_US-<name>-<quality>` — underscore + uppercase
   region. Both filenames must match exactly.
3. That's it — no catalog editing. On a synthesize request, `ensure_voice_exists()` sees
   the name is not in the bundled `voices.json` catalog and falls through to `find_voice()`,
   which simply looks for `<name>.onnx(.json)` in `/data`. Voices load on-demand and are
   cached, so **no container restart is needed** to add one. `--voice` in compose only sets
   the *default*; Wyoming clients (Home Assistant) can request any installed voice by name.

**Gotcha (this bit us a year ago):** if the files are named with hyphens/lowercase locale
(e.g. `en-us-glados-high`) or the two filenames don't match, you get `VoiceNotFoundError`.
Rename to the `en_US-...` scheme. The voice's display name comes from the filename, not a
field inside the `.onnx.json`.

Install procedure (from a workstation that has the files):
```sh
scp my-voice.onnx      sanctioned@jarvis:/tmp/en_US-myvoice-high.onnx
scp my-voice.onnx.json sanctioned@jarvis:/tmp/en_US-myvoice-high.onnx.json
ssh sanctioned@jarvis 'D=/opt/homelab/ai/wyoming-piper/data; \
  sudo mv /tmp/en_US-myvoice-high.onnx* "$D"/ && \
  sudo chown root:root "$D"/en_US-myvoice-high.onnx* && sudo chmod 644 "$D"/en_US-myvoice-high.onnx*'
```

### Installed voices & provenance (binaries not in git)
| Voice (data-dir name)      | Source |
|----------------------------|--------|
| `en_US-lessac-medium`      | Official, auto-downloaded by piper from [rhasspy/piper-voices](https://huggingface.co/rhasspy/piper-voices). |
| `en_US-glados-high`        | GLaDOS (Portal). Sourced from [AIHeaven/piper_unofficial_voices](https://huggingface.co/AIHeaven/piper_unofficial_voices) (`en_us-glados-high`); renamed to the `en_US-` scheme. Added 2026-06-17. |

### Pending / backlog
- **Jarvis voice** — the `jarvis-*.onnx` files in our voice stash are Git-LFS **pointer
  stubs** (133 bytes), not the real models; need the real binaries (e.g. from
  [rhasspy/piper-voices #11](https://huggingface.co/rhasspy/piper-voices/discussions/11))
  before they can be installed as `en_US-jarvis-{high,medium}`.
- **Cortana (Halo)** — no public *English* Cortana Piper voice exists; the only one is
  Spanish ([HirCoir es_MX-Cortana](https://huggingface.co/HirCoir/piper-voice-es_MX-Cortana-CE-Legacy),
  trained on the Halo Spanish dub). An English Cortana would require training (e.g. via
  [TextyMcSpeechy](https://github.com/domesticatedviking/TextyMcSpeechy) on the RTX 3090).
  Deferred to a follow-up project.

## Issues & Fixes

**Symptom:** The image pull failed because the originally-specified tag did not exist.
**Fix:** use `rhasspy/wyoming-piper:2.2.2`.

**Symptom:** A custom voice fails with `VoiceNotFoundError`.
**Fix:** rename to the `en_US-<name>-<quality>` scheme (underscore + uppercase region) and
ensure the `.onnx` and `.onnx.json` filenames match exactly. No catalog edit is required.

## Secrets
- None. `TZ` is inherited from the environment where applicable.
- All secrets come from `/opt/homelab/.env` (gitignored); nothing sensitive is committed.
