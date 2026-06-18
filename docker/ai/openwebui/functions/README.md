# OpenWebUI Functions

Custom OpenWebUI **Pipe** functions (each appears as a selectable "model" in the chat model picker).

## `n8n_bleenq_kb.py` — KB: Bleenq Knowledge

Routes a chat to the n8n **`kb-chat`** workflow — the AI Agent over the **whole Bleenq KB library**
(every KB in [`docs/kb-manifest.json`](../../../../docs/kb-manifest.json): homelab, trading, design, …).
The agent enumerates the KBs and retrieves from whichever collection(s) are relevant, then answers.
The Open WebUI chat id is passed as the n8n `sessionId`, so memory is scoped per conversation.

- **Transport:** internal docker network — `http://n8n:5678/webhook/bleenq-kb-chat/chat` (OpenWebUI and
  n8n share the `ai` network; no Traefik round-trip). Verified working from the `openwebui` container.
- **Requires:** the `kb-chat` workflow **active** with `public: true` on its Chat Trigger.

### Install (Admin UI — ~30s, no rebuild)

1. OpenWebUI → **Admin Panel → Functions → `+` (Add Function)**.
2. Paste the contents of `n8n_bleenq_kb.py`, **Save**.
3. **Enable** the function. It appears in the model picker as **"KB: Bleenq Knowledge"**.
4. (Optional) gear → **Valves** to set `n8n_url`, a `bearer_token`, or the timeout.

> Replaces the earlier single-KB `n8n_kb_homelab_docs.py` ("KB: Homelab Docs"). If that one is still
> installed, delete it in Admin → Functions so you don't have two KB models.

> Functions live in OpenWebUI's database, not on disk — this file is the source-of-truth copy for
> version control / re-import. Update here and re-paste when changed.

### Notes

- The agent occasionally wraps its answer in a ```` ```json ```` fence; the pipe strips a single outer
  fence (`strip_code_fences` valve, on by default).
- No secrets in this file. If you later gate the n8n webhook, put the token in the `bearer_token` valve
  (stored in OpenWebUI), **not** in the committed source.
