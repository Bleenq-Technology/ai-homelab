# Wyoming Piper
**Purpose:** Text-to-speech (TTS) over the Wyoming protocol.
**URL:** TCP port 10200 (raw Wyoming protocol — not behind Traefik)
**Auth:** none (LAN/Wyoming protocol)
**Image:** rhasspy/wyoming-piper:2.2.2
**GPU:** yes (NVIDIA reservation, `count: all`)
**Networks / data:** ai; bind mount `./wyoming-piper/data` -> `/data`

## Setup as deployed
- Command: `--voice en_US-amy-medium` (the **default** voice; clients may request any other
  installed voice per-utterance).
- Published as raw TCP `10200:10200` so Wyoming clients (e.g. Home Assistant) can connect
  directly; it speaks the Wyoming TCP protocol, not HTTP, so it is **not routed through Traefik**.
- GPU access via the compose NVIDIA device reservation.
- Voice/model data persists under `./wyoming-piper/data`.

## Voice discovery (client enumeration)
A Wyoming client enumerates voices via the **Describe → Info** handshake: connect to
`tcp://<host>:10200`, send a `Describe` event, and the server replies with an `Info` event
whose `tts[0].voices` lists every available voice (Home Assistant uses this to populate its
voice dropdown). The server advertises the **full ~150-voice built-in catalog plus any custom
voices** found in `/data` (verified 2026-06-17: 151 voices advertised). All catalog voices are
reported `installed=True` and download on first use, so the dropdown shows far more than what's
physically in `/data`.

## Custom / extra voices

> **Community voice catalog:** [`piper-voice-catalog.html`](piper-voice-catalog.html) — a researched
> list of third-party Piper voices (HAL-9000, GLaDOS, Wheatley, Kronk, the real **`jgkawell/jarvis`**
> voice, etc.) with HuggingFace download links. Open it in a browser to browse candidates to install.

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
| `en_US-amy-medium` **(default)** | Official, auto-downloaded from [rhasspy/piper-voices](https://huggingface.co/rhasspy/piper-voices). Set as the default voice 2026-06-17 (natural neutral female). |
| `en_US-lessac-medium`      | Official, auto-downloaded by piper from [rhasspy/piper-voices](https://huggingface.co/rhasspy/piper-voices). Previous default. |
| `en_US-glados-high`        | GLaDOS (Portal). Sourced from [AIHeaven/piper_unofficial_voices](https://huggingface.co/AIHeaven/piper_unofficial_voices) (`en_us-glados-high`); renamed to the `en_US-` scheme. Added 2026-06-17. |
| `en_US-jarvis-high`        | JARVIS (Paul Bettany, Iron Man). MIT. Real binary downloaded **on the host** from [jgkawell/jarvis](https://huggingface.co/jgkawell/jarvis) `en/en_GB/jarvis/high/` (sha256 `9791877d…`, 114 MB); renamed to the `en_US-` scheme. Added 2026-06-25. |
| `en_US-jarvis-medium`      | JARVIS, medium quality. Same source, `en/en_GB/jarvis/medium/` (sha256 `3f6534bd…`, 63.5 MB). Added 2026-06-25. |

> **How these were installed (2026-06-25):** the `jarvis-*.onnx` files in our local voice stash
> were Git-LFS **pointer stubs** (133/134 bytes), not real models. jarvis can reach HuggingFace
> directly, so we `curl`-ed the real binaries **on the host** (avoids the Windows-LFS dance),
> verified each `sha256sum` against the stub's recorded `oid`, then `sudo mv`'d them into the data
> dir as `en_US-jarvis-{high,medium}` (`root:homelab` 664). Verified by a raw Wyoming `synthesize`
> request (4.4 s of 22050 Hz audio). The voice's `.onnx.json` `dataset` field stays `jarvis-high`
> — irrelevant to wyoming-piper, which keys on the **filename** (see the gotcha above).

### Pending / backlog
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
