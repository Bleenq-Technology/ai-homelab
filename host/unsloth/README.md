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
| `unsloth-studio.service.d/override.conf` | **Our** drop-in: model, quant, `--max-seq-length 32768`, `--parallel 2` | `/etc/systemd/system/unsloth-studio.service.d/override.conf` |

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

## Model & sizing (why these values)
- **Model:** `unsloth/Qwen3-8B-GGUF`, quant **UD-Q4_K_XL** (~4.8 GB weights). An 8B
  **text-only** model — chosen over the (newer, multimodal) Qwen3.5 line specifically so **no
  vision projector is loaded**: we don't use vision, and Studio auto-attaches an `--mmproj`
  for any multimodal repo with no opt-out. Text-only ⇒ no projector ⇒ no wasted VRAM. The
  8B is a clear step up from the previous 4B for tool-calling / instruction-following in the
  n8n agents and curation flows.
- **Context:** `--max-seq-length 32768` (`-c 32768`) with `--parallel 2` ⇒ two concurrent
  16k-token slots. The KV cache scales with total `-c`, so this is the main VRAM lever:
  shrinking from the old **256k** down to **32k** is what frees the GPU.
- **`enable_thinking: false`** — forced via `--chat-template-kwargs '{"enable_thinking":
  false}'` in the override. Studio defaults thinking **on** for Qwen3-8B, but the `<think>`
  blocks slow replies and break the n8n AI-Agent's tool-call parsing, so we turn it off
  (faster, and the correct behaviour for tool-use). Our pass-through is last-wins over
  Studio's auto-added `enable_thinking: true`.

## GPU / VRAM budget (RTX 3090, 24 GB)
| Consumer | VRAM |
|----------|------|
| This LLM (8B UD-Q4_K_XL @ 32k ctx, 2 slots) | **~8 GB** |
| `bge-m3` embeddings (1024-dim) | ~0.9 GB |
| ComfyUI | bursty — loads only while generating (run with `--disable-smart-memory` so it frees VRAM when idle) |

That leaves **~15 GB free** for ComfyUI and other GPU workloads. (The previous 4B @ 256k ctx
used ~12.8 GB — almost entirely oversized KV cache, since the 4B weights were only ~3 GB.)

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
  **discord-curator** also pins this name in its `dc-config.json`.
- GPU is shared with **ComfyUI**; budget the 24 GB accordingly if adding more GPU workloads.
