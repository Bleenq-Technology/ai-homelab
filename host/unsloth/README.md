# unsloth — host LLM service (not Docker)

The local LLM (`unsloth/Qwen3.5-4B-GGUF`, OpenAI-compatible on `:8888`) runs as a
**host systemd service on jarvis**, *outside* the Docker stack, so it can own the GPU
directly. The rest of the lab reaches it at `http://192.168.2.10:8888/v1` (or, preferred,
through the **LiteLLM** gateway which traces to Langfuse).

This folder version-controls the service definition so the deployment is reproducible:

| File | What it is | On jarvis |
|------|-----------|-----------|
| `unsloth-studio.service` | Base unit — **created by the Unsloth Studio installer** (reference only) | `/etc/systemd/system/unsloth-studio.service` |
| `unsloth-studio.service.d/override.conf` | **Our** drop-in: `--max-seq-length 262144` (256k context) | `/etc/systemd/system/unsloth-studio.service.d/override.conf` |

## Why the override
The model and llama.cpp support a **256k** context window natively, but Unsloth Studio
defaults `--max-seq-length` to **65536** — which overflowed on web-search-heavy chats. The
256k KV cache is already allocated (it's why llama-server uses ~12.8 GB), so raising the
served limit costs **no extra VRAM**.

## Deploy / re-apply

1. Install Unsloth Studio (creates `/opt/unsloth`, the `unsloth` user, and the base unit).
2. Apply our override:
   ```bash
   sudo mkdir -p /etc/systemd/system/unsloth-studio.service.d
   sudo install -m 0644 host/unsloth/unsloth-studio.service.d/override.conf \
     /etc/systemd/system/unsloth-studio.service.d/override.conf
   sudo systemctl daemon-reload
   sudo systemctl restart unsloth-studio.service
   ```
3. Verify:
   ```bash
   sudo systemctl cat unsloth-studio.service | grep max-seq-length    # -> 262144
   ps -ef | grep "unsloth run" | grep -o "max-seq-length [0-9]*"
   systemctl is-active unsloth-studio.service                          # -> active
   ```

## Notes & gotchas
- **Edit the model/flags via the override**, not the base unit — a Studio reinstall/upgrade
  may regenerate the base unit, but the drop-in survives (and is re-appliable from here).
- The restart drops the LLM for ~30–60 s while the 4B model reloads (Open WebUI chats blip).
- GPU is shared with **ComfyUI** (run with `--disable-smart-memory` so it frees VRAM when idle).
  Budget the 24 GB accordingly if adding more GPU workloads.
- To change the context size, edit `--max-seq-length` here, copy to the host, `daemon-reload`,
  restart. 262144 is the model's native max; a smaller value (e.g. 131072) also works.
