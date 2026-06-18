# BGE-M3 embeddings (llama.cpp)
**Purpose:** Local, GPU-accelerated **BGE-M3** text embeddings (1024-dim) over an OpenAI-compatible
API, served to the whole lab through **LiteLLM** so apps don't each wire their own embedder.
**URL:** in-cluster only — `http://bge-m3:8080/v1` (`ai` network). **No Traefik route.**
**Auth:** none (internal `ai` net, same posture as ComfyUI). Reached via LiteLLM as model `bge-m3`.
**Image:** `ghcr.io/ggml-org/llama.cpp:server-cuda`, **pinned by digest** `sha256:8d9129ac…` (build b9692).
**GPU:** yes (NVIDIA reservation, `count: all`). VRAM ~0.7 GB (Q8_0) — trivial vs the shared 24 GB.

## Setup as deployed
- **Model:** `bge-m3-Q8_0.gguf` (~635 MB) from [`ggml-org/bge-m3-Q8_0-GGUF`](https://huggingface.co/ggml-org/bge-m3-Q8_0-GGUF),
  downloaded into the host bind mount `./bge-m3/models` → `/models`. **Not committed** (gitignored `*.gguf`).
- **Command:** `--embeddings --pooling cls -c 8192 -b 8192 -ub 8192 -ngl 99 --host 0.0.0.0 --port 8080`.
- **Wired into LiteLLM** as `model_name: bge-m3` → `openai/bge-m3` at `http://bge-m3:8080/v1`
  (dummy `api_key`, unused). Use it anywhere via the gateway:
  ```python
  from openai import OpenAI
  c = OpenAI(base_url="http://litellm:4000/v1", api_key="<LITELLM key>")
  c.embeddings.create(model="bge-m3", input="hello world")   # -> 1024-dim vector
  ```

## Gotchas (why the flags matter)
- **`--pooling cls`** — BGE-M3's dense embedding is the CLS-token state. Mean pooling gives wrong vectors.
- **`-b 8192 -ub 8192` (== `-c`)** — BGE-M3 is a *non-causal encoder*; the batch must span the whole
  context or llama.cpp errors. So batch/ubatch are set equal to the 8192-token context.
- **Pinned by digest**, not a moving `server-cuda` tag — reproducible builds (no `latest`).
- The image is minimal (no `curl`/`wget`), so there's no container healthcheck; check readiness via
  `docker logs bge-m3 | grep "model loaded"` or hit `/health` from another container.

## Reproduce the model download (on jarvis)
```bash
mkdir -p /opt/homelab/ai/bge-m3/models
curl -fL -o /opt/homelab/ai/bge-m3/models/bge-m3-Q8_0.gguf \
  https://huggingface.co/ggml-org/bge-m3-Q8_0-GGUF/resolve/main/bge-m3-q8_0.gguf
```

## Secrets
- None. The endpoint is unauthenticated on the `ai` net; LiteLLM holds the (unused) placeholder key.
