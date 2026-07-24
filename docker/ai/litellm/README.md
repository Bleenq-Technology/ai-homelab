# LiteLLM

> **On LiteLLM's 2026 CVEs (the question everyone asks):** we run a **patched** build (`v1.89.1`, above the fixed `v1.83.14-stable`), the admin/proxy port `:4000` is **internal-only** (never host-published), the edge returns 401 to unauth requests, every change is CI-scanned (Trivy + AI review), and the gateway is wrapped in the scoped-key + audit governance layer. We evaluated moving to Kong and **chose to stay** — see [`docs/gateway-decision.md`](../../../docs/gateway-decision.md) (`todos.md` #5). Short version: swapping a patched, wrapped, internal gateway for a heavier one with its own advisory history is a lateral move, and our whole governance layer is LiteLLM-key-shaped.

**Purpose:** OpenAI-compatible gateway in front of the local unsloth LLM that logs **every** call to Langfuse — one chokepoint for centralized LLM tracing.
**URL:** https://litellm.lab.example (API) — in-cluster: `http://litellm:4000`
**Auth:** **API** — per-app **virtual key** (Bearer); the master key is administrative only. **Admin UI (`/ui`)** — **Keycloak SSO** (native OIDC), see below.
**Image:** `ghcr.io/berriai/litellm:main-stable`
**Networks / data:** `proxy` + `ai` + `data` (Postgres for the virtual-key store); config at [`config.yaml`](config.yaml)

## Setup as deployed
- **Upstreams / models:**
  - `unsloth/Qwen3-8B-GGUF` (chat) → unsloth host at `http://192.168.2.10:8888/v1` (key `UNSLOTH_API_KEY`).
  - `bge-m3` (1024-dim embeddings) → the `bge-m3` llama.cpp container at `http://bge-m3:8080/v1`
    (ai-net internal, no auth — see [`../bge-m3/README.md`](../bge-m3/README.md)).
  - **`openrouter/*` (third-party, added 2026-07-23)** → OpenRouter, key `OPENROUTER_TOKEN`:
    `openrouter/claude-sonnet-5`, `openrouter/gpt-5-mini`, `openrouter/gemini-2.5-flash-lite`.
    Reached only by the `openwebui-external` virtual key ($5/30d budget).
    See [Third-party models](#third-party-models-via-openrouter) below.
- **Langfuse logging:** `success_callback`/`failure_callback: ["langfuse"]`; `LANGFUSE_PUBLIC_KEY`/`LANGFUSE_SECRET_KEY`
  + `LANGFUSE_HOST=http://langfuse-web:3000` (internal). Verified: calls appear as `litellm-acompletion` traces.
- **Master key:** `LITELLM_MASTER_KEY` — clients send `Authorization: Bearer <key>`.
- **Virtual keys (per-app):** backed by Postgres DB `litellm`
  (`DATABASE_URL=postgresql://litellm:${LITELLM_DB_PASSWORD}@postgres:5432/litellm`; LiteLLM runs
  its Prisma migrations on startup). Mint a scoped key with the master key:
  `POST /key/generate {"key_alias":"<app>","models":["unsloth/Qwen3-8B-GGUF","bge-m3"]}` → returns `sk-…`.
  Scope the key to **every** model the app uses (chat + embeddings) — a missing model 403s with
  `key_model_access_denied`. Add a model to an existing key via `POST /key/update {"key":"sk-…","models":[…]}`.
  Revoke/rotate per app via `/key/delete` and `/key/generate` without rotating the master key.
  Existing keys: **`assistant-app`** (Assistant voice-assistant project, 2026-06-17) — scoped to
  `unsloth/Qwen3-8B-GGUF` + `bge-m3` (chat + embeddings); **`web-app`** (public chat BFF +
  its n8n node, 2026-06-22) — same scope, stored in Infisical as `WEB_APP_LLM_KEY` (revoke
  via `/key/delete` to instantly kill the public bot); **`example-site`** (the second public
  chat — The Example Playbook™ site, 2026-07-15) — same chat + `bge-m3` scope, a **separate**
  key from `web-app` (one scoped key per public surface), stored in Infisical as
  `EXAMPLE_SITE_LLM_KEY`; **`home-assistant`** (the HA hub *friday*'s
  Assist conversation agent, 2026-06-26) — **chat-only** scope (`unsloth/Qwen3-8B-GGUF`, no
  embeddings), stored in Infisical as `HOME_ASSISTANT_LLM_KEY`. HA is off-box on the IoT VLAN, so
  it reaches the gateway at `https://litellm.lab.example/v1` (not `http://litellm:4000`).
- Routed at `litellm.${DOMAIN}` with `secure-chain@file` (master-key auth, **not** SSO). Add a
  `litellm.lab.example → 192.168.2.10` EdgeRouter mapping for by-name access.

## Admin UI login (Keycloak SSO)

**URL:** `https://litellm.${DOMAIN}/ui/` → redirects to Keycloak; sign in with your homelab account.

Before 2026-07-22 the UI was gated only by the **master key used as a web password**, reachable from
any LAN/VPN device — the weakest link in the key chain, since that UI can **mint and revoke every
virtual key** and read all spend. Native OIDC gives real **per-user identity**: you can see *who*
minted or revoked a key.

- Keycloak client: [`../../core/keycloak/provision-litellm-client.sh`](../../core/keycloak/provision-litellm-client.sh)
  (confidential, exact redirect `https://litellm.${DOMAIN}/sso/callback` — Keycloak 26 rejects
  wildcards). Secret in Infisical as `LITELLM_OIDC_CLIENT_SECRET`.
- Env: `PROXY_BASE_URL`, `GENERIC_CLIENT_ID/SECRET`, and the three Keycloak endpoints
  (`GENERIC_AUTHORIZATION_ENDPOINT` / `_TOKEN_ENDPOINT` / `_USERINFO_ENDPOINT`). The token+userinfo
  ones are **required** — LiteLLM raises a 500 naming them if unset.
- **Master-key login still works** as a break-glass fallback if Keycloak is down.

> **⚠️ Free-tier cap: 5 users.** Generic OIDC SSO needs **no enterprise licence** while
> `LiteLLM_UserTable` holds **≤ 5 users** *and* a DB is connected — verified by reading `ui_sso.py`
> in `v1.89.1`, not from docs. **Every distinct Keycloak user who logs in becomes a row** counting
> toward the 5; the 6th gets a hard **403**, not a graceful degrade. (A separate, flat "Enterprise
> required" gate exists on `/sso/debug/login` — an experimental debug route that does *not* affect
> normal UI login. Easy to find that message and wrongly conclude SSO is fully paywalled.)

**Don't gate the whole host with `secure-sso@file`** — the router stays `secure-chain@file` because a
302 to Keycloak would break every programmatic client (assistant-app, both public chats, HA, research,
n8n). SSO is handled *inside* LiteLLM, on the UI routes only. The
`litellm-admin-ui-sso-enforced` eval guards against a silent regression to password login.

## Usage
```python
from openai import OpenAI
client = OpenAI(base_url="http://litellm:4000/v1", api_key="<LITELLM_MASTER_KEY>")  # in-cluster
client.chat.completions.create(model="unsloth/Qwen3-8B-GGUF",
                               messages=[{"role": "user", "content": "hi"}])
```
Every call is traced in Langfuse. To trace **OpenWebUI** too, set its
`OPENAI_API_BASE_URL=http://litellm:4000/v1` and key = the master key.

## Third-party models via OpenRouter

Added **2026-07-23**. Until then the gateway was local-only, which was a strong privacy posture but
meant we could never demonstrate the gateway's actual point: that a **third-party** model is subject
to the same scoping, budget, rate limit and trace attribution as a local one. These three make that
demonstrable, across three different vendors through one key.

| Model in the picker | Upstream | $/1M in → out | Context |
|---|---|---|---|
| `openrouter/claude-sonnet-5` | Anthropic | $2.00 → $10.00 | 1M |
| `openrouter/gpt-5-mini` | OpenAI | $0.25 → $2.00 | 400k |
| `openrouter/gemini-2.5-flash-lite` | Google | $0.10 → $0.40 | 1M |

### Which spend limits actually enforce (measured 2026-07-23)

Don't assume any of these — most don't work. Tested by pushing **5 × 13k tokens through in one
minute** against a 40,000 tpm ceiling:

| Control | Result |
|---|---|
| `litellm_params: tpm` / `rpm` (deployment level) | ❌ **not enforced** — all 65k passed |
| + `router_settings.enable_pre_call_checks: true` | ❌ not enforced |
| + `routing_strategy: usage-based-routing-v2` | ❌ not enforced |
| Virtual-key `tpm_limit` | ❌ **not enforced** — all 65k passed |
| Virtual-key `rpm_limit` | ✅ **enforced** — 19×200, 6×429 `Limit type: requests` |
| Virtual-key `max_budget` | ✅ **enforced** — 429 `budget_exceeded` |
| `model_max_budget` (per-model $ cap on a key) | 🔒 requires an **enterprise licence** (400) |

Deployment-level `rpm`/`tpm` are **routing hints** for choosing between multiple deployments of one
model — with a single deployment they bound nothing. That's why `config.yaml` carries none of them:
config that lies is worse than no config.

**So the spend control is the key, not the model.** `openwebui-external` carries **`max_budget` $5 /
30d** and **`rpm_limit` 20**, the two that were proven to bite. The $5 binds *before* the $10 prepaid
OpenRouter credit (auto-recharge OFF), so there's headroom rather than a hard stop at the wall.

**Why a separate key from `openwebui`.** Put that $5 budget on the shared key and a demo overspend
would 429 **local** chat and OpenWebUI's RAG embeddings too. Split, the blast radius stays on the paid
models — and Langfuse attributes external spend to its own alias, so "what did we send off-box?" is a
query, not an inference. Open WebUI holds both via `OPENAI_API_BASE_URLS`/`OPENAI_API_KEYS`
(`;`-separated, zipped positionally — keep the lists same-length and same-order).

**The `openrouter/` prefix is load-bearing.** It's what a user sees in the OpenWebUI picker, so "this
prompt leaves the box" is legible at the point of use instead of buried in config. See
[`docs/ai-acceptable-use.md`](../../../docs/ai-acceptable-use.md) §5.

**`:free` is deliberately not configured** — free variants generally route to providers that may train
on submitted prompts, which conflicts with the `internal` data class OpenWebUI carries.

### Gotcha: reasoning models need `max_tokens` headroom
`gpt-5-mini` is a reasoning model and its **reasoning tokens count against `max_tokens`**. At
`max_tokens: 20` it returns `content: null` with an empty string — it *looks* like a broken model but
the budget was spent thinking. Measured: at `max_tokens: 600` the same prompt used 93 completion
tokens, **64 of them reasoning**. OpenWebUI doesn't set a small cap, so this only bites scripted calls.

### Exposing a new model to an app
Models are **key-scoped** — adding one to `config.yaml` does *not* make it visible to any app. Update
the app's virtual key too, or it 403s with `key_model_access_denied`:
```bash
# /key/update with the FULL model list (it replaces, not appends)
curl -sX POST https://litellm.${DOMAIN}/key/update \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" -H 'Content-Type: application/json' \
  -d '{"key":"<hashed-token-from-/key/list>","models":["unsloth/Qwen3-8B-GGUF","bge-m3","openrouter/claude-sonnet-5"]}'
```
Then mirror the same list into that system's `models:` in `docs/ai-inventory.yml` — the AI-BOM live
check raises `model_scope_drift` when the key and the inventory disagree (negative-tested). A brand-new
key also needs its own inventory entry, or the check FAILS it as an `unregistered_credential`.

## Secrets
- `.env` keys: `LITELLM_MASTER_KEY`, `UNSLOTH_API_KEY`, `LITELLM_DB_PASSWORD`, `LANGFUSE_PUBLIC_KEY`,
  `LANGFUSE_SECRET_KEY`, `OPENROUTER_TOKEN`, `OPENWEBUI_EXTERNAL_LLM_KEY`. All in Infisical; nothing committed to git. Per-app
  virtual keys live in the `litellm` Postgres DB (not in `.env`).
  - `OPENROUTER_TOKEN` must also be passed through in `compose.ai.yml` — without it LiteLLM starts
    **cleanly** and only fails at call time with a 401, so a missing key presents as a model outage
    rather than a config error.

## Issues & Fixes
**Symptom:** test call returned `000` right after recreate.
**Fix:** none needed — LiteLLM takes ~20-30 s to start (it initializes the Langfuse callback); the call
succeeds once `Uvicorn running on 0.0.0.0:4000` appears in the logs.
