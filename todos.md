# Homelab — Open TODOs

Backlog of new work for the `jarvis` homelab stack. Each item is sized to be picked up
**one at a time, paired with Claude Code**, and finished with **its own commit**. They're
written as goals + guard-rails, not recipes — let Claude Code propose the concrete config,
review it together, deploy, verify, then commit.

> **Cross-project intake:** sibling projects (e.g. `trading-engine`) file items here when they hit a
> capability that belongs at the **platform** layer rather than in their own repo. If you're an infra
> session, this is the queue — including entries added by other projects (they'll say so + give the rationale).

---

## How we work here (read this first)

A few conventions that apply to every item below:

- **Repo → server.** This repo's `docker/` directory is the source of truth. The live stack
  runs on **jarvis** at `/opt/homelab` (which mirrors `docker/`). To deploy a change you
  `scp` the changed file(s) to jarvis and run `docker compose up -d <service>` there.
  `/opt/homelab` is **not** a git repo — never sync the whole tree (it would clobber the real
  `.env`); copy individual files.
- **Three Docker networks** decide who can talk to whom:
  - `proxy` — anything Traefik needs to route to (gets a web URL).
  - `ai` — the AI/LLM services (LiteLLM, OpenWebUI, ComfyUI, n8n, …).
  - `data` — the datastores (Postgres, Qdrant, ClickHouse, QuestDB, MinIO, Redis).
  A container only needs to join the networks it actually talks on.
- **Exposure / auth via Traefik labels.** Attach one middleware chain:
  - `secure-sso@file` → hardened **and** gated behind Keycloak SSO (use for anything sensitive).
  - `secure-chain@file` → hardened but **public** (no login). Use only when something is meant
    to be seen without auth, and make sure it leaks nothing sensitive.
- **New hostname?** Add an internal DNS mapping on the EdgeRouter (`firewall.pdx`, the router)
  pointing the new `*.pdx.sanctioned.tech` name at jarvis. Ask Paul to add it (he keeps those).
- **Secrets** live in **Infisical**, never hardcoded. Set them there, then `./pull-secrets.sh`
  on jarvis regenerates `.env`. (Writing to Infisical from jarvis has two gotchas — Claude Code
  has them noted; ask it.)
- **Quality bar:** pin image versions (no `latest`), GPU containers follow the ComfyUI pattern,
  test the thing actually works before committing, **scan staged changes for secrets before every
  commit** (see TODO 6 — we're heading toward open-sourcing this), and write a clear commit message.
  One commit per TODO below.

---

## 1. Home Dashboard (public landing page)

**Goal.** A friendly landing page that lists the apps we run, grouped and ordered, that even a
**non-logged-in** person can view. Show live **up/down status** per app, and make it easy to
re-order and group. It should also hold **links to off-box things** we'll add later (Home
Assistant, the NAS, etc.).

**Suggested approach.** Use **[Homepage](https://gethomepage.dev)** (`gethomepage/homepage`) —
it's config-driven, supports ordered groups, per-service health pings, and an **Uptime Kuma**
widget so the status dots come straight from the monitor we already run (which also feeds the
Discord alerts). Dashy/Heimdall/Glance are alternatives, but Homepage fits best. Pick a hostname
like `home.pdx.sanctioned.tech` (or make it the default landing page).

**Guard-rails.**
- This page is **public** → route it with `secure-chain@file`, **not** `secure-sso`. Because
  it's public, only put **names, links, and up/down** on it — no API keys, no internal metrics,
  no secret widget data.
- Pull status from the existing **Uptime Kuma** rather than re-inventing health checks.
- Group by audience (e.g. "Everyday" with OpenWebUI first, then "AI tools", "Admin", "Storage").
- Add placeholder bookmark entries for the off-box services so the layout is ready for them.

**Done when:** the page loads without login, lists today's apps in sensible groups, shows live
status, leaks nothing sensitive, DNS resolves, and it's committed.

---

## 2. Embedding model container (bge-m3, GPU) wired into LiteLLM

**Goal.** A small GPU-accelerated container serving the **BGE-M3** embedding model
(1024-dimensional) over an OpenAI-compatible API, registered in **LiteLLM** so every app gets
embeddings through the same gateway (instead of each wiring its own).

**Suggested approach.** Run **llama.cpp's server** in embedding mode with the model
**`bge-m3-Q8_0.gguf`**, GPU layers offloaded to the RTX 3090. Mirror the existing **ComfyUI**
service for the GPU bits (NVIDIA runtime + a mounted models directory for the `.gguf`). Then add
a **model entry in LiteLLM** pointing at this container's `/v1/embeddings` endpoint, named
something like `bge-m3`.

**Guard-rails.**
- Networks: `ai` only (LiteLLM and apps reach it internally) — it needs **no public route**.
- The 3090 is **shared** (unsloth on the host, ComfyUI). BGE-M3 Q8 is small (well under 1 GB
  VRAM), but note the VRAM budget so nothing gets starved.
- Keep the model file out of git — download it into the mounted models dir on jarvis.

**Done when:** hitting the embeddings endpoint returns a **1024-length vector**, LiteLLM lists
`bge-m3` and proxies to it successfully, and it's committed. (This unblocks TODO 4.)

---

## 3. n8n MCP server container

**Goal.** Run an **n8n MCP server** so LLM tools can list/trigger our n8n workflows over MCP,
authenticated with an n8n API key.

**Suggested approach.** Deploy the n8n MCP server (e.g. the community `n8n-mcp`) as a container.
Create an **API key inside n8n** (n8n → Settings → API), point the MCP at n8n's internal URL
(`http://n8n:5678`) with that key.

**Guard-rails.**
- Networks: `ai` (to reach `n8n:5678`) and `proxy` (only if it needs a web/MCP route — otherwise
  keep it internal).
- Store the n8n API key in **Infisical**, not in the compose file.
- If it does get a route, gate it with `secure-sso@file` — it can drive workflows, so it's
  sensitive. Pin the image version.

**Done when:** the MCP server starts, authenticates to n8n, and can list/trigger a workflow;
committed.

---

## 4. Qdrant MCP server (FastMCP) wired into LiteLLM + Qdrant

**Goal.** A **Qdrant MCP server** (FastMCP-based) that lets tools store/search vectors in our
Qdrant, using our own embedding model via LiteLLM's OpenAI-compatible API.

**Suggested approach.** Deploy the official **`mcp-server-qdrant`** (built on FastMCP). Point it
at Qdrant (`http://qdrant:6333`) and configure its embeddings to go through **LiteLLM's
OpenAI-compatible endpoint** (e.g. `http://litellm:4000/v1`) using the **`bge-m3`** model from
TODO 2.

**Guard-rails.**
- **Do TODO 2 first** — this depends on the `bge-m3` model existing in LiteLLM.
- Networks: `data` (reach `qdrant:6333`), `ai` (reach LiteLLM), and `proxy` (if it needs a
  route — gate with `secure-sso@file` if so).
- Keep the Qdrant API key and LiteLLM key in **Infisical**.

**Done when:** the MCP server starts and can create a collection + store/search vectors in Qdrant
using BGE-M3 embeddings served through LiteLLM; committed.

## 5. Evaluate replacing LiteLLM with Kong AI Gateway (free CE)

**Why.** LiteLLM had a cluster of **actively-exploited critical CVEs** in 2026 — RCE
`CVE-2026-42271` (in CISA's KEV catalog), unauth SQLi `CVE-2026-42208` (CVSS 9.3, exploited within
36h), a CVSS 9.9 low-priv→host-RCE chain, and auth-bypass `CVE-2026-49468`. We're currently pinned
to a **patched** `litellm:v1.89.1` (above the fixed `v1.83.14-stable`), so this is **not an
emergency** — it's a trust / attack-surface decision after the project's rough security year.

**Goal.** Decide whether to replace LiteLLM with **Kong AI Gateway (free CE/OSS)** as the unified
OpenAI-compatible LLM gateway (used by Open WebUI, the future bge-m3 embeddings in TODO 2, the
trading app, and the Qdrant MCP in TODO 4). Kong's `ai-proxy` plugin gives the same multi-provider
OpenAI-compatible routing on a mature OpenResty core.

**Evaluate / guard-rails.**
- Confirm the **CE edition** covers our needs: OpenAI-compatible `/v1/chat/completions` **and**
  `/v1/embeddings`, multiple upstreams (unsloth on the host, cloud providers, the bge-m3 container),
  per-route API keys. Advanced bits (semantic cache, prompt guard, advanced rate-limit) are
  **Enterprise** — confirm we don't depend on them.
- Weigh **operational cost**: Kong is heavier than LiteLLM. Prefer **DB-less declarative** mode for a
  homelab (no extra Postgres dependency).
- Also glance at **Apache APISIX** (AI plugins) and **Portkey** as alternatives before deciding.
- A swap touches everything pointing at `http://litellm:4000` (Open WebUI, the MCPs, TODOs #2 & #4).

**Done when:** a short written recommendation (swap or stay, with a CE-feature-fit verdict); if
swapping, Kong CE deployed DB-less on the `ai`/`proxy` networks, the OpenAI endpoints re-pointed and
verified, LiteLLM removed — committed.

## 6. Secrets hygiene — pre-commit scanning + pre-open-source history scrub

**Why.** We intend to **open-source this stack** (with write-ups). Two gaps: nothing automated stops
a secret reaching git, and the git **had one since-rotated secret, now scrubbed.**
Realm-seed client secrets were always placeholders, never real.

**Goal.** Make "no secret ever reaches git" enforceable, and clean existing history before going public.
- **Pre-commit scanning:** wire up **`infisical scan`** (it's gitleaks under the hood) —
  `infisical scan install --pre-commit-hook` for a local git hook, and/or an `infisical scan` step in
  CI. Catches secrets *before* the commit lands.
- **History audit:** run `infisical scan` / `gitleaks detect` over the **full history**; for every hit,
  **rotate** the secret and **scrub** history (`git filter-repo` or BFG) before the repo is public.
- **Discipline (every commit, starting now):** manually scan staged changes for secrets — the same pass
  we did on the realm seed (client secrets, SMTP creds, private keys, high-entropy tokens). Claude Code
  should do this automatically before any commit.

**Done when:** the pre-commit hook is installed + documented, a clean full-history scan report exists,
and any historical secrets are rotated + scrubbed — committed.

---

_Tip for Jacob: start with #1 (self-contained, very visual, great for getting the deploy loop in
your hands), then #2 (unblocks #4). #5 and #6 are security/hygiene tracks — #6 should land before we
publish anything. Tell Claude Code the goal and the guard-rails above; let it draft the compose +
config; review it with these notes; deploy; verify the "Done when"; commit (after a secret scan)._
