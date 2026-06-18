# OpenWebUI Functions

Custom OpenWebUI **Pipe** functions (each appears as a selectable "model" in the chat model picker).

## `n8n_kb_homelab_docs.py` — KB: Homelab Docs

Routes a chat to the n8n **`kb_homelab_docs-chat`** workflow (AI Agent + Qdrant retrieval over the
homelab docs KB — see [`../../n8n/workflows/`](../../n8n/workflows/)). Each message is POSTed to the
n8n Chat Trigger webhook; the agent's answer comes back as the assistant reply. The OpenWebUI chat id
is passed as the n8n `sessionId`, so the agent's Window Buffer Memory is scoped per conversation.

- **Transport:** internal docker network — `http://n8n:5678/webhook/kb-homelab-docs-chat/chat`
  (OpenWebUI and n8n share the `ai` network; no Traefik round-trip). Verified working from the
  `openwebui` container.
- **Requires:** the `kb_homelab_docs-chat` workflow **active** with `public: true` on its Chat Trigger.

### Install (Admin UI — ~30s, no rebuild)

1. OpenWebUI → **Admin Panel → Functions → `+` (Add Function)**.
2. Paste the contents of `n8n_kb_homelab_docs.py`, **Save**.
3. **Enable** the function. It now appears in the model picker as **"KB: Homelab Docs"**.
4. (Optional) Click the gear to edit **Valves** — e.g. set `n8n_url`, a `bearer_token`, or timeout.

> Functions live in OpenWebUI's database, not on disk, so this file is the source-of-truth copy for
> version control / re-import. Update here and re-paste when changed.

### Notes

- The agent occasionally wraps its answer in a ```` ```json ```` fence; the pipe strips a single
  outer fence (`strip_code_fences` valve, on by default).
- No secrets in this file. If you later gate the n8n webhook, put the token in the `bearer_token`
  valve (stored in OpenWebUI), **not** in the committed source.
