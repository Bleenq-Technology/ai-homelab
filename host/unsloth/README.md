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
| `unsloth-studio.service.d/override.conf` | **Our** drop-in: model, quant, `--max-seq-length 65536`, `--parallel 2`, q8_0 KV cache | `/etc/systemd/system/unsloth-studio.service.d/override.conf` |

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
- **Context:** `--max-seq-length 65536` (`-c 65536`) with `--parallel 2` ⇒ two concurrent
  **32k-token slots**. 32k/slot is sized to hold OpenWebUI's web-search results (full page
  text is injected, not summarized — ~20k-token prompts), which overflowed the earlier
  16k/slot (`-c 32768`) window. The KV cache scales with total `-c`, so context is the main
  VRAM lever — but see the q8_0 KV trick below, which is what makes a 64k context affordable.
- **KV cache `q8_0`:** `--cache-type-k q8_0 --cache-type-v q8_0` stores the KV cache at 8-bit
  instead of f16, roughly **halving** its VRAM. This is what lets us double the context (32k →
  64k total) for ~no extra VRAM vs the old 32k-f16 config. q8_0 KV is effectively lossless for
  chat/tool-use and requires flash-attn (Studio enables it). Still well above the old **256k**,
  so the GPU stays freed.
- **`enable_thinking: false`** — forced via `--chat-template-kwargs '{"enable_thinking":
  false}'` in the override. Studio defaults thinking **on** for Qwen3-8B, but the `<think>`
  blocks slow replies and break the n8n AI-Agent's tool-call parsing, so we turn it off
  (faster, and the correct behaviour for tool-use). Our pass-through is last-wins over
  Studio's auto-added `enable_thinking: true`.

## GPU / VRAM budget (RTX 3090, 24 GB)
| Consumer | VRAM |
|----------|------|
| This LLM (8B UD-Q4_K_XL @ 64k ctx, 2× 32k slots, q8_0 KV) | **~9–10 GB** |
| `bge-m3` embeddings (1024-dim) | ~0.9 GB |
| ComfyUI | bursty — loads only while generating (run with `--disable-smart-memory` so it frees VRAM when idle) |

That leaves **~13 GB free** for ComfyUI and other GPU workloads. (The previous 4B @ 256k ctx
used ~12.8 GB — almost entirely oversized KV cache, since the 4B weights were only ~3 GB.)
The q8_0 KV cache is the key trick: a 64k-f16 KV would push this to ~14 GB, but at q8_0 the
64k context costs about the same as the original 32k-f16 config.

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
