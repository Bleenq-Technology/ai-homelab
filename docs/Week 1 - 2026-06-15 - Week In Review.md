# Week 1 — Week In Review
**Period:** 2026-06-15 → 2026-06-18 · **Repos:** ai-homelab-infra, apollo, trading-engine, discord-curator

**Bottom line:** we went from *one hand-built KB* to a **manifest-driven, multi-repo knowledge platform** —
four live knowledge bases (~1,100 chunks), a single AI chat that routes across all of them in OpenWebUI, a
reusable retrieval API the whole app fleet can call, the two consumer apps wired into it, and a brand-new
sibling project scaffolded and shipped to GitHub. Four repos touched, ~9 commits, a safety tag, zero
secrets leaked.

## 🧠 Knowledge base library (`ai-homelab-infra`)
- Built the first KB end-to-end in n8n (ingest + chat) **without the n8n-mcp helper tools loading** — drove
  the n8n-mcp binary over a hand-rolled stdio JSON-RPC bridge to pull node schemas instead.
- Generalized it into a **manifest-driven library**: one `kb-manifest.json` → a Python generator → all
  workflows. *Add a KB = edit one file.*
- **4 KBs live** (homelab, trading, design, apollo), all `bge-m3` / 1024-dim / Cosine, ingested from GitHub
  (markdown-only), nightly rebuild + manual.
- **One cross-KB chat**: an agent that enumerates the KBs and routes each question to the right
  collection(s) — verified (trading Q → trading KB, homelab Q → homelab KB, "what KBs?" → no wasted
  retrieval).

## 🔌 Shared access layer + fleet integration
- Built reusable **`kb-search`** and **`kb-list`** HTTP endpoints (server-side embedding) — the
  `kb-standards.md` §5 access layer made real (see `kb-access-layer.md`).
- Wired **Apollo** and **trading-engine** docs to it so those agents read the same KBs instead of siloing RAG.

## 💬 OpenWebUI
- Custom **"KB: Bleenq Knowledge"** pipe function — the whole KB library answerable from the chat box.

## 🤖 New project: `discord-curator`
- Designed + scaffolded a sibling app (Discord links → curated `kb_research_*` KBs): full
  docs/architecture/roadmap/schema, pushed to the org — ready for its own build session.

## 🛠️ Ops fixes along the way
- Caught a **stale `GITHUB_PAT`** (401s) and resynced `.env` from Infisical surgically; sorted n8n CLI
  broker-port conflicts, the `public:true` webhook gotcha, credential-update quirks, and a GitHub
  raw-content header — plus a fallback `kb-v1` tag before the big refactor.

---

## ⏱️ How long by hand? (for giggles)
Realistically **~2–3 focused weeks solo (~80–120 hrs)** for someone competent across n8n, Qdrant, LiteLLM,
OpenWebUI internals, and Discord — longer if learning any of them. The *building* isn't the expensive part;
it's the **rabbit holes** — the silent n8n-mcp tool-load failure, the 401 that looked like an n8n bug but
was a stale env var, the chat webhook 404 that needed one obscure flag. Those are where solo days quietly
disappear. We compressed that into a few sessions by diagnosing against the live stack and keeping moving.

## 🤝 How the collaboration went
Really well — and the *shape* of it is why. The human set direction and made the calls (KB-per-repo vs
pooled, "make it the shared layer," the rename, parking v2); the agent executed, verified every step against
the real services, and surfaced gotchas + a recommendation rather than just asking. We checkpointed before
risky refactors, course-corrected fast (a repo-name typo), and kept secrets out of git the whole way.
Human steering architecture + agent handling the fiddly execution and dead-ends turned out to be a genuinely
high-leverage combo.

*A lot of durable platform built in a short window.* 🎉
