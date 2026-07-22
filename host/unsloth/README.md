# unsloth — host LLM service (not Docker)

The local LLM (`unsloth/Qwen3-8B-GGUF`, OpenAI-compatible on `:8888`) runs as a
**host systemd service on jarvis**, *outside* the Docker stack, so it can own the GPU
directly (host process, not a container, on purpose for perf). The rest of the lab reaches
it at `http://192.168.2.10:8888/v1` (or, preferred, through the **LiteLLM** gateway which
traces to Langfuse).

This folder version-controls the service definition so the deployment is reproducible:

| File | What it is | On jarvis |
|------|-----------|-----------|
| `unsloth-studio.service` | Base unit — **created by the Unsloth Studio installer** (reference only; its `--model` is illustrative) | `/etc/systemd/system/unsloth-studio.service` |
| `unsloth-studio.service.d/override.conf` | **Our** drop-in: model, quant, `--max-seq-length 81920`, `--parallel 2`, q8_0 KV cache | `/etc/systemd/system/unsloth-studio.service.d/override.conf` |

## How it's wired (`:8888` ↔ `:49057`)
`unsloth run` (the Unsloth **Studio** CLI, the process the systemd unit launches) listens on
`:8888` and **manages a `llama-server` subprocess** that it binds on an internal port (e.g.
`:49057`), reverse-proxying HTTP to it. So `:8888` is the stable public endpoint; the
`llama-server` port is an implementation detail Studio owns — don't point clients at it.
Studio derives the `llama-server` command line from the unit's args:

- `--model` / `--gguf-variant` → which GGUF to download from HF + pass as `-m`.
- `--max-seq-length` → llama.cpp's total context `-c`.
- Studio also auto-adds `--flash-attn on`, `-ngl -1` (all layers on GPU), `--jinja`,
  and `--no-context-shift`.
- **Everything else passes through** to `llama-server` (last-wins), which is how `--parallel 2`
  takes effect. Studio only *blocks* model-identity, networking, and auth flags from
  pass-through (see its `llama_server_args.py` denylist); tunables like `-c`, `--parallel`,
  `--flash-attn`, `-ngl`, `--cache-type-*` are all overridable.

## Who may reach `:8888` (network guard — added 2026-07-22)
Studio is launched with **`-H 0.0.0.0`**, so before this it accepted connections from the **entire
LAN** — any workstation, phone, or IoT-VLAN device could hit the shared model **directly, bypassing
the LiteLLM gateway** and therefore every governance property that depends on it: per-system virtual
keys, tier rate limits, and the Langfuse trace. `UNSLOTH_API_KEY` gates it, but that's **one static
shared token** with no per-consumer identity, no rotation, and no expiry — it tells us nothing about
*who* called.

**Why not just change the bind address?** LiteLLM reaches unsloth at the host's LAN IP
(`192.168.2.10:8888`) from inside a Docker network, so `-H 127.0.0.1` breaks the gateway, and binding
to any single Docker gateway IP breaks the other networks. A **port-scoped firewall rule** is the
correct control.

[`unsloth-firewall.sh`](unsloth-firewall.sh) builds an `UNSLOTH-GUARD` iptables chain allowing
**loopback + `172.16.0.0/12` (all Docker bridge networks)** and rejecting everything else on `:8888`
with a TCP reset (fast "connection refused" beats a hang when debugging; stealth buys nothing on our
own LAN). It's idempotent — the chain is flushed and rebuilt, and the `INPUT` jump is inserted only
if absent.

**It is re-applied at boot by [`unsloth-firewall.service`](unsloth-firewall.service)** — iptables
rules don't survive a reboot and this host runs no ufw/nftables service, so without the unit the
guard would silently vanish on the next power cycle (and jarvis *does* get power-cycled). Verified:
LAN → `connection refused`, `ai`-net container → `401` (reachable, key required), host loopback →
`401`, and a chat completion through LiteLLM still succeeds.

```bash
sudo install -m 0755 unsloth-firewall.sh /usr/local/sbin/unsloth-firewall.sh
sudo install -m 0644 unsloth-firewall.service /etc/systemd/system/
sudo systemctl daemon-reload && sudo systemctl enable --now unsloth-firewall
sudo iptables -L UNSLOTH-GUARD -n     # inspect
```

**Gotcha:** the guard means a LAN host can no longer test unsloth directly. Test **through LiteLLM**
(which is the intended path anyway) or from a container / the host itself.

## Startup banner leaks a key (redacted, not silenceable — 2026-07-22)
Studio prints a startup banner containing **`API Key: sk-unsloth-…`** and (before `-q`) example
`curl -H "Authorization: Bearer <key>"` lines. Promtail ships journald here, so with 30-day Loki
retention those tokens were searchable in Grafana (`todos.md` #49). Findings, in order of what they
change:

- **`-q` removes the `curl … Bearer` example lines** — the worse leak (they printed the key inside an
  `Authorization:` header). It's in the `ExecStart` now. Verified it does **not** suppress operational
  logs (`request_completed`, model-load, errors still print), so it's a clean win.
- **`--silent`/`-q` does NOT remove the `API Key:` line itself** — that key still hits journald. But it
  is **redacted in Loki** by Promtail's `\bsk-` rule (verified stored as `API Key: sk-<REDACTED>`), so
  it doesn't reach Grafana.
- **The printed key is NOT the gateway credential.** It differs from `UNSLOTH_API_KEY` (SHA mismatch)
  and **changes on every boot**, so Studio mints a per-boot display key separate from the credential
  LiteLLM authenticates with. That makes the residual lower still — the raw journald line exposes a
  rotating, non-gateway key to someone who already has host access.

**Net residual:** the `API Key:` line remains in raw host journald (host-access-only). Compensating
controls: Promtail redaction (Grafana-safe), the localhost-only firewall guard (above), and the fact
that it isn't the gateway key. Not worth further effort unless Studio adds a true no-banner flag.

## Model & sizing (why these values)
- **Model:** `unsloth/Qwen3-8B-GGUF`, quant **UD-Q4_K_XL** (~4.8 GB weights). An 8B
  **text-only** model — chosen over the (newer, multimodal) Qwen3.5 line specifically so **no
  vision projector is loaded**: we don't use vision, and Studio auto-attaches an `--mmproj`
  for any multimodal repo with no opt-out. Text-only ⇒ no projector ⇒ no wasted VRAM. The
  8B is a clear step up from the previous 4B for tool-calling / instruction-following in the
  n8n agents and curation flows.
- **Context:** `--max-seq-length 81920` (`-c 81920`) with `--parallel 2` ⇒ two concurrent
  **40k-token slots**. 40,960 is **exactly the model's native context** (the GGUF's
  `qwen3.context_length=40960`), so we get the largest window the model handles *without* rope
  scaling — no YaRN, no long-context quality degradation. 40k/slot comfortably holds OpenWebUI's
  web-search results (full page text is injected, not summarized), which overflowed the first
  16k/slot (`-c 32768`) window and were tight at 32k/slot. Going beyond 40k/slot would need YaRN
  (or the separate `unsloth/Qwen3-8B-128K-GGUF` variant) **and** more VRAM — see the budget below.
- **KV cache `q8_0`:** `--cache-type-k q8_0 --cache-type-v q8_0` stores the KV cache at 8-bit
  instead of f16, roughly **halving** its VRAM. That's what keeps an 80k context affordable
  (~6 GB of q8 KV vs ~12 GB at f16). q8_0 KV is effectively lossless for chat/tool-use and
  requires flash-attn (Studio enables it). Still far below the old **256k**, so the GPU stays freed.
- **`enable_thinking: false`** — forced via `--chat-template-kwargs '{"enable_thinking":
  false}'` in the override. Studio defaults thinking **on** for Qwen3-8B, but the `<think>`
  blocks slow replies and break the n8n AI-Agent's tool-call parsing, so we turn it off
  (faster, and the correct behaviour for tool-use). Our pass-through is last-wins over
  Studio's auto-added `enable_thinking: true`.

## GPU / VRAM budget (RTX 3090, 24 GB)
| Consumer | VRAM |
|----------|------|
| This LLM (8B UD-Q4_K_XL @ 80k ctx, 2× 40k slots, q8_0 KV) | **~11 GB** |
| `bge-m3` embeddings (1024-dim) | ~0.9 GB |
| ComfyUI | bursty — loads only while generating (run with `--disable-smart-memory` so it frees VRAM when idle) |

That leaves **~12 GB free** for ComfyUI and other GPU workloads. (The previous 4B @ 256k ctx
used ~12.8 GB — almost entirely oversized KV cache, since the 4B weights were only ~3 GB.)
KV is linear in total `-c`: at q8_0 each ~16k of total context is ~1.2 GB. For reference —
`-c 65536` (32k/slot) ≈ 10 GB total / ~13 GB free; `-c 81920` (40k/slot, native) ≈ 11 GB /
~12 GB free; `-c 131072` (64k/slot, **needs YaRN**) ≈ 15 GB / ~8 GB free. We run the native
80k as the sweet spot — biggest no-rope-scaling window with ComfyUI headroom intact.

## Deploy / re-apply
1. Install Unsloth Studio (creates `/opt/unsloth`, the `unsloth` user, and the base unit).
2. (Optional, to minimize downtime) pre-fetch the GGUF into Studio's HF cache:
   ```bash
   sudo -u unsloth HOME=/opt/unsloth \
     /opt/unsloth/.unsloth/studio/unsloth_studio/bin/python -c \
     "from huggingface_hub import hf_hub_download; hf_hub_download('unsloth/Qwen3-8B-GGUF','Qwen3-8B-UD-Q4_K_XL.gguf')"
   ```
3. Apply our override:
   ```bash
   sudo mkdir -p /etc/systemd/system/unsloth-studio.service.d
   sudo install -m 0644 host/unsloth/unsloth-studio.service.d/override.conf \
     /etc/systemd/system/unsloth-studio.service.d/override.conf
   sudo systemctl daemon-reload
   sudo systemctl restart unsloth-studio.service
   ```
4. Verify:
   ```bash
   systemctl is-active unsloth-studio.service                                   # -> active
   ps -ef | grep llama-server | grep -o -E "Qwen3-8B[^ ]*|-c [0-9]*|--parallel [0-9]*"
   nvidia-smi --query-gpu=memory.used,memory.free --format=csv                  # used ~8 GB
   curl -s http://192.168.2.10:8888/v1/models                                   # lists the model
   ```

## Swapping the model / context later
Edit **`override.conf`** (never the base unit — a Studio reinstall/upgrade may regenerate the
base, but the drop-in survives and is re-appliable from here), then copy to the host,
`daemon-reload`, restart:
- **Different model:** change `--model` (and `--gguf-variant` to match an available quant). Pick
  a **text-only** repo unless you actually want vision — a multimodal repo pulls an `--mmproj`.
- **Context:** change `--max-seq-length` (and `--parallel` for the per-slot split). Bigger ctx
  ⇒ bigger KV cache ⇒ more VRAM; budget against the 24 GB table above.

## Notes & gotchas
- The restart drops the LLM for ~30–60 s while the model reloads (Open WebUI / KB-chat blip).
- **Downstream model-name references** must match `--model`: LiteLLM
  [`config.yaml`](../../docker/ai/litellm/config.yaml), `docs/kb-manifest.json` (`chat_model`,
  which regenerates the n8n `kb-chat` workflow), and the various READMEs. The cross-repo
  **content-curator** also pins this name in its `dc-config.json`.
- GPU is shared with **ComfyUI**; budget the 24 GB accordingly if adding more GPU workloads.
