# Knowledge-Base (RAG) Standards — Jarvis platform

The contract every app/agent follows so **one set of KBs is shared, consistent, and discoverable**
across OpenWebUI, Apollo, the trading code, n8n flows, and anything we add later. Platform-layer
standard — apps reference it; they don't reinvent it.

> **Status:** agreed 2026-06-18. Tooling: **n8n** is the primary ingestion/orchestration engine
> (Flowise is deprecated/parked — see `docker/ai/flowise/README.md`). Shared access layer: the
> **Qdrant MCP** (`todos.md` #4) — not yet built.

---

## 1. Embedding standard (non-negotiable — it's what makes KBs interoperable)

- **Model:** `bge-m3` via the **LiteLLM** gateway (`POST {litellm}/v1/embeddings`, model `bge-m3`).
- **Dimension:** **1024**. **Distance:** **Cosine** (BGE-M3 output is L2-normalised).
- A Qdrant collection's vector size is **fixed at creation** — you cannot mix embedders in one
  collection. **Every writer and reader of a KB must embed with `bge-m3`**, or retrieval silently
  returns garbage / errors on dimension mismatch.
- Don't embed with an app-local model (e.g. OpenWebUI's old CPU MiniLM-384). All routes go through
  LiteLLM so every embed is **Langfuse-traced** and centrally swappable.

## 2. A KB == a Qdrant collection

| Naming | Meaning | Who reads it |
|--------|---------|--------------|
| **`kb_<domain>`** | **Shared** KB — discoverable, cross-app | any agent (via the MCP) |
| **`<app>_<purpose>`** | **App-private** working memory | only that app |

Examples — shared: `kb_homelab_docs`, `kb_trading_learnings`, `kb_trading_code`. Private:
`apollo_memory`, `apollo_episodic`, `trading_scratch`. *Domain ≠ owner:* `kb_trading_*` is a shared
KB about trading that Apollo may also search; the trading **app's** private store is `trading_*`.

Two storage patterns (pick per KB):
- **Collection-per-KB** (default): clean isolation, "list KBs" = "list `kb_*` collections", drop a KB
  = drop a collection.
- **One collection + payload `kb` tag + filter**: fewer collections, cross-KB search, easier ACLs —
  use at scale.

## 3. Payload schema (standard fields on every point)

Required for citations, filtering, and dedup:

```jsonc
{
  "text":         "the chunk text",          // shown in answers / citations
  "source":       "https://… | /path | s3://bucket/key | discord:msg_id",
  "source_type":  "git | file | youtube | web | discord | book",
  "title":        "doc or section title",
  "kb":           "kb_homelab_docs",          // redundant but handy in multi-KB collections
  "chunk_index":  0,
  "content_hash": "sha256(chunk)",            // dedup key (see §4)
  "ingested_at":  "2026-06-18T00:00:00Z",
  "tags":         ["optional", "labels"]
}
```

## 4. Dedup / idempotency (don't re-ingest)

- **Chunk-level:** `content_hash = sha256(normalised chunk text)`; skip upsert if the hash already
  exists in the collection (Qdrant filter, or use the hash as the point id).
- **Source-level:** keep a ledger of processed sources (URL/object-key/etag/discord-msg-id) so a
  re-run doesn't re-fetch+re-embed. Ledger lives in **Postgres** (n8n already uses it) or a Baserow
  table. Essential for the Discord-harvest project (lots of repeat links).

## 5. Discovery & access — the Qdrant MCP (todos #4)

KBs are useless if agents can't find them. The **shared access layer** is one MCP server exposing:
- `list_kbs()` → the `kb_*` collections + descriptions (from the **registry**, §6)
- `search_kb(name, query, k)` → embeds the query with `bge-m3`, returns top-k with payload/citations

Every MCP-capable agent (n8n, Apollo, OpenWebUI tool servers, future Flowise/agents) gets the **same
list + search** instead of each siloing its own RAG. **Caveat:** OpenWebUI's built-in *Knowledge*
feature manages its own `open-webui_*` collections and won't natively see a `kb_*` collection — to
give OpenWebUI shared KBs, wire it to the MCP tool rather than its Knowledge UI.

## 6. KB registry (source of truth for "what's searchable")

A small table mapping: `name → description → collection → embedder → owner → visibility`. Agents read
it to route queries to the right KB. Implement as a Baserow table (human-editable) or a Postgres
table; the MCP serves it via `list_kbs()`.

## 7. Optional graph layer — Neo4j (GraphRAG)

For relationship-heavy KBs (e.g. **`kb_trading_code`** call-graphs/deps, or linked trading concepts),
add a Neo4j graph alongside the vectors: extract entities+relations (LLM-assisted) → store in Neo4j →
multi-hop queries. Add **only where vector RAG isn't enough**; expose through the same MCP later.

## 8. Ingestion patterns (n8n flows)

- **Git-native** (cleanest): for KBs whose source already lives in a repo (`kb_homelab_docs`,
  `kb_trading_code`) — n8n `git pull` → glob files → chunk → embed → upsert. No drop zone needed.
- **Human drop zone:** **MinIO** (already deployed) — drop files via the `minio.pdx` web console or
  S3 API; MinIO **bucket-notification events → n8n webhook** (event-driven, no polling). One
  bucket/prefix per KB; move processed objects to a `processed/` prefix or rely on §4 hash-dedup.
- **Links/URLs:** n8n HTTP/yt-dlp/WhisperX (YouTube), web fetch → extract → chunk → embed → upsert.
- **Discord harvest (future):** a Baserow table of channels with a `harvest` flag + target KB;
  n8n reads it, pulls links/messages, dedups (§4), routes to the KB.

**Every ingestion flow ends the same way:** chunk → `bge-m3` embed (via LiteLLM) → upsert to the KB
collection with the §3 payload, honouring §4 dedup.

## 9. Per-app responsibilities

- **Apollo:** owns app-private `apollo_*` (its memory). **Reads** shared `kb_*` via the MCP. Must
  create any collection at **1024/Cosine** with `bge-m3` (the old 384-dim `apollo_memory` was dropped
  2026-06-18). See Apollo `CLAUDE.md`.
- **trading-engine:** owns `trading_*` private; contributes to shared `kb_trading_*`. See its platform
  guide (`trading-engine/docs/Jarvis_Platform_Services.md`).
- **homelab/n8n:** builds/maintains the shared `kb_*` ingestion flows and the registry + MCP.

---
*Canonical copy: this file. Apps summarise + link here; they don't fork the standard.*
