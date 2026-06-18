# Using n8n from Claude Code (n8n-mcp)

[`n8n-mcp`](https://github.com/czlonkowski/n8n-mcp) is an MCP server that turns Claude Code into a
reliable n8n workflow builder: it gives the model **node schemas/docs for all ~1,845 nodes +
validation**, and — with an API key — the ability to **create / update / execute workflows** on our
n8n (`https://n8n.pdx.sanctioned.tech`, API route is `secure-chain-stream`, **not** SSO-gated).

## 1. Get an n8n API key

**Recommended — mint your own** (so it can be revoked per-developer):
1. n8n → your account → **Settings → n8n API → Create an API key**.
2. Label it (e.g. `claude-<yourname>`) and copy it — it's shown **once**.

**Or — use the shared platform key from Infisical** (if you have access):
- Infisical UI → `https://infisical.pdx.sanctioned.tech` → project **homelab** → env **prod** →
  secret **`N8N_API_KEY`** (reveal/copy).
- Or on jarvis: `ssh sanctioned@jarvis 'grep ^N8N_API_KEY= /opt/homelab/.env'`.
- ⚠️ This is a **shared** key — revoking it breaks everyone. Prefer your own (above) for daily use.

The key is a JWT (`eyJ…`). It grants **full n8n API access** (create/run workflows) — treat it as a
secret; never commit it.

## 2. Add the MCP to Claude Code

**Linux / macOS / WSL / Git Bash:**
```bash
claude mcp add n8n-mcp \
  -e MCP_MODE=stdio -e LOG_LEVEL=error -e DISABLE_CONSOLE_OUTPUT=true \
  -e N8N_API_URL=https://n8n.pdx.sanctioned.tech \
  -e N8N_API_KEY=<your-key> \
  -- npx n8n-mcp
```

**Windows PowerShell:**
```powershell
claude mcp add n8n-mcp `
  '-e MCP_MODE=stdio' '-e LOG_LEVEL=error' '-e DISABLE_CONSOLE_OUTPUT=true' `
  '-e N8N_API_URL=https://n8n.pdx.sanctioned.tech' `
  '-e N8N_API_KEY=<your-key>' `
  -- npx n8n-mcp
```

Notes:
- `N8N_API_URL` is the **base** host — the MCP appends `/api/v1` itself.
- This uses the **default `local` scope**: the key is stored in your `~/.claude.json` (per-project),
  **not** committed. **Do not** use `-s project` — that writes the key into a committed `.mcp.json`.
- Requires Node (the `npx` fetches `n8n-mcp` on first run).

## 3. Reload + verify

- **Restart / reconnect your Claude Code session** — MCP tools only load at session start, so a server
  added mid-session won't appear until you reconnect.
- Check it's live: `claude mcp list` → `n8n-mcp … ✔ Connected`.
- Smoke test: ask Claude *"list available n8n trigger nodes"* or *"list n8n workflows"*.

> **Reliability tip — if `claude mcp list` says Connected but the tools never appear in the assistant:**
> the **cold `npx` first run** (it downloads + builds a node DB) can overrun the session's MCP-init
> window, leaving it "connected" with zero tools. Fix: install it as a real binary and point the config
> at that instead of `npx`:
> ```bash
> npm install -g n8n-mcp
> claude mcp remove n8n-mcp
> claude mcp add n8n-mcp -e MCP_MODE=stdio -e LOG_LEVEL=error -e DISABLE_CONSOLE_OUTPUT=true \
>   -e N8N_API_URL=https://n8n.pdx.sanctioned.tech -e N8N_API_KEY=<your-key> -- n8n-mcp
> ```
> The installed binary starts instantly, so the tools enumerate on the next reconnect.

## Security / housekeeping
- Keys are full-access and **don't expire** unless you set an expiry at creation — rotate/revoke in
  **Settings → n8n API** when a dev leaves or a key leaks.
- Without an API key, n8n-mcp still works in **read-only** mode (node docs + validation) — handy if you
  only want help *designing* workflows.
- A **shared, deployed** n8n-mcp HTTP service (so other agents/apps can drive n8n, not just Claude Code)
  is tracked as a platform backlog item — see `../../../todos.md` #3.
