# Week 1 — Week In Review
**Period:** 2026-06-15 → 2026-06-18 · **Scope:** the homelab platform, its AI core, OpenWebUI, Apollo, and
the new knowledge layer · **Repos:** ai-homelab-infra, apollo, trading-engine, discord-curator

**Bottom line:** in one week we stood up and hardened a full self-hosted AI homelab, **unified its AI core
behind a single traced gateway**, validated the user-facing capabilities (chat, web search, image
generation), brought a **custom Windows voice assistant onto the platform end-to-end**, and built a
**manifest-driven multi-KB knowledge platform** with a shared retrieval API — plus scaffolded and shipped a
brand-new sibling project. Four repos, ~36 running services, an AI core wired into two apps, and a
knowledge layer the whole fleet can call.

## 🏗️ Platform & hardening (`ai-homelab-infra`)
- **~36-container stack** deployed and verified on jarvis (RTX 3090), all web routes live behind Traefik.
- **~40 images version-pinned + CVE-audited**, upgraded and rolled out one-at-a-time with verification and
  pre-upgrade backups.
- **Monitoring + alerting:** Prometheus / Alertmanager → Discord (GPU/CPU temp, disk, memory, container
  OOM/restart, etc.); Grafana dashboards for host/GPU/containers/Postgres/Redis/traffic.

## 🔐 Auth & SSO — including non-federated apps
- Migrated central forward-auth to **oauth2-proxy v7.15.3** (Keycloak OIDC), one auth domain
  (`auth.pdx…`), Redis-backed sessions, single shared cookie.
- **Native OIDC** for the apps that support it (Grafana, OpenWebUI, Portainer, Langfuse); **forward-auth
  (`secure-sso`) for everything that doesn't** — so non-federated apps get SSO with **no per-app redirect
  URI**, just a middleware flip.
- Rotated leaked client secrets across Keycloak/Infisical/apps; tamed the CSRF-cookie redirect loop and the
  MLflow host-header guard along the way.

## 🧩 AI core — unified + monitored
- **LiteLLM gateway** fronting the on-host **unsloth Qwen3.5-4B** chat model **and the GPU `bge-m3`
  embedding service** — one OpenAI-compatible endpoint, one key, every call traced.
- **Langfuse** as the LLM analytics/trace surface (prompts, tokens, latency, cost) for every OpenWebUI /
  LiteLLM completion.
- **Virtual keys** for clean per-app onboarding (Apollo et al.); LiteLLM moved to Postgres-backed.

## 💬 OpenWebUI — capabilities integrated + validated
- **Web search** (Tavily, RAG-optimized, with a private **SearXNG** fallback) → embed → Qdrant retrieve →
  grounded answers, hallucination-curbing template.
- **Image generation** via **ComfyUI** (SDXL) wired in and validated end-to-end.
- Switched its vector store to the **shared Qdrant** (replacing embedded Chroma) so RAG is persistent and
  shared.

## 🧠 Knowledge platform (`ai-homelab-infra`)
- Built the first KB end-to-end in n8n **without the n8n-mcp helper tools loading** — drove the n8n-mcp
  binary over a hand-rolled stdio JSON-RPC bridge to pull node schemas.
- Generalized into a **manifest-driven library**: one `kb-manifest.json` → a Python generator → all
  workflows. *Add a KB = edit one file.*
- **4 KBs live** (homelab, trading, design, apollo), all `bge-m3` / 1024-dim / Cosine, ~1,100 chunks.
- **One cross-KB chat** that enumerates the KBs and routes each question to the right collection(s) —
  verified — surfaced in OpenWebUI as the **"KB: Bleenq Knowledge"** model.
- **Reusable `kb-search` / `kb-list` access layer** (`kb-standards.md` §5, `kb-access-layer.md`); **Apollo +
  trading-engine** wired to it so the fleet shares one RAG layer.

## 🎙️ Apollo — voice assistant on the platform (`apollo`)
- A **custom Windows-native voice assistant** integrated and validated against the **full platform**:
  **STT (Whisper) · TTS (Piper) · LLM (LiteLLM/Qwen) · Embeddings (bge-m3) · KB reads (shared `kb_*`) ·
  Web Search** — all heavy compute offloaded to Jarvis, private memory in `apollo_*` Qdrant.

## 🤖 New project: `discord-curator`
- Designed + scaffolded a sibling app (Discord links → curated `kb_research_*` KBs): full
  docs/architecture/roadmap/schema, pushed to the org — ready for its own build session.

## 🛠️ Ops fixes along the way
- Caught a **stale `GITHUB_PAT`** (401s) and resynced `.env` from Infisical surgically; sorted n8n CLI
  broker-port conflicts, the `public:true` webhook gotcha, credential-update quirks, and a GitHub
  raw-content header — plus a fallback `kb-v1` tag before the big refactor.

---

## ⏱️ How long by hand? (for giggles)
This is no longer a "couple of weeks" job. A full self-hosted AI homelab (≈36 services, SSO, monitoring,
version-pinned + CVE-checked), a **unified, traced AI core**, OpenWebUI with validated web-search + image
gen, a **multi-KB knowledge platform with a shared API**, *and* a **custom Windows voice assistant wiring
together six platform capabilities** — solo, that's realistically **~2–4 months of focused full-time work**,
more while learning any of the moving parts (Keycloak/oauth2-proxy, LiteLLM, Langfuse, n8n internals,
Qdrant/RAG, ComfyUI, Whisper/Piper, Discord). And again — the *building* isn't the costly part; the
**rabbit holes** are (a 401 that was a stale env var, a CSRF cookie loop, a webhook 404 needing one obscure
flag). We compressed that by diagnosing against the live stack and never losing momentum.

## 🤝 How the collaboration went
Really well — and the *shape* of it is why. The human set direction and made the calls (architecture,
trade-offs, scope, "make it the shared layer," parking v2); the agent executed, **verified every step
against the real services**, and surfaced gotchas + a recommendation rather than just asking. We
checkpointed before risky refactors, course-corrected fast, and kept secrets out of git the whole way.
Human steering + agent handling the fiddly execution and dead-ends turned out to be a genuinely
high-leverage combo.

*A remarkable amount of durable platform built in a single week.* 🎉
