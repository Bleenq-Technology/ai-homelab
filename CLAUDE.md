# ai-homelab-infra — Claude Code working notes

**Read this first.** It's the orientation + the cross-cutting rules and non-obvious
gotchas for working in this repo. The deep how-to lives in the docs linked at the
bottom — this file points you there, it doesn't duplicate them.

This repo defines the **homelab Docker stack** (plus a couple of host-level services)
for the server **jarvis**. It's edited **locally** (Windows + Claude Code) and **deployed
to jarvis by copying files up** — there is **no git on the host**.

## Who works here
Two developers — **`sanctioned`** (Paul) and **`jacob`** (his son) — each connect as
**their own user**. Both are in the **`homelab`** group with **passwordless sudo**. Because
either of us may pick up the other's work, the shared-permission rules below are not
optional — follow them so the other dev can always edit what you pushed.

## Connecting to jarvis
- `ssh Jarvis` (the configured host alias — **case-sensitive**), or `sanctioned@jarvis` /
  `jacob@jarvis`, or the IP **`192.168.2.10`**. Connect as **yourself**, not as the other user.
- Docker from your machine: `docker context use jarvis` (or `docker --context jarvis …`).
- The live deploy tree on the host is **`/opt/homelab`** — it mirrors this repo's **`docker/`**
  directory (the `docker/` prefix is dropped: `docker/ai/litellm/config.yaml` →
  `/opt/homelab/ai/litellm/config.yaml`). Host-level services live under this repo's `host/`.

---

## Deploy model — repo → host (the golden rules)

1. **`/opt/homelab` is NOT a git repo.** Deploy by `scp`-ing the **individual changed files**
   to their matching path under `/opt/homelab`. **Never rsync/sync the whole tree** — it would
   clobber the host-local real `.env` (and other generated/host-only files).
2. **After any `scp`/copy into `/opt/homelab`, fix group-write:**
   ```bash
   ssh Jarvis 'sudo chmod -R g+rwX /opt/homelab'
   ```
   We standardize on **`scp`** (rsync isn't reliable on our Windows machines). scp lands files
   as **`0644` (owner-write only)** — it ignores the dir's setgid/ACLs/umask — so without this
   fixup the *other* developer can't edit your pushed files without sudo. `g+rwX` adds group
   read/write and execute/traverse only where already executable (safe over the whole tree).
   - **Do NOT widen secret files.** `/opt/homelab/.env` is `640`, the `.env*.bak` /
     `.infisical-auth` are `600` by design — `g+rwX` leaves them correct; never make them more
     permissive.
   - Some dirs under `/opt/homelab` are **root-owned** (e.g. `core/keycloak/`). For those, scp
     to `/tmp` then `sudo install -m 0644 /tmp/x /opt/homelab/<path>` (the pattern we use for
     the unsloth systemd override too).
3. **Recreate to apply.** Compose and `.env` changes only take effect on a **service recreate**:
   ```bash
   ssh Jarvis 'cd /opt/homelab && docker compose -f compose.yml up -d <service>'
   ```
   Always drive the **aggregate `compose.yml`** (project `homelab`, `include:`s the four layer
   files). Never `docker compose -f ai/compose.ai.yml up -d <svc>` directly — `container_name`
   collisions ("name already in use"). Traefik `core/traefik/config/dynamic.yml` is
   **hot-reloaded** (file provider) — no restart needed.
4. **Host-level services are NOT Docker.** `host/unsloth/` (the local LLM) and `host/wireguard/`
   run on the host. unsloth is a **systemd service** (`unsloth-studio.service` + our drop-in
   override); deploy = `sudo install` the override to `/etc/systemd/system/...`, `daemon-reload`,
   `restart`. See [host/unsloth/README.md](host/unsloth/README.md).

## Secrets — Infisical is the source of truth
- Real secrets live in **Infisical** (project `homelab`, env `prod`). `/opt/homelab/.env` is a
  **generated artifact** — `pull-secrets.sh` truncates and regenerates it. **Never hand-edit
  `.env` on the host**; add/change via `push-secret.sh KEY VALUE` then `./pull-secrets.sh` then
  recreate the service. Writing to Infisical from jarvis has two gotchas (the `source ./` path
  and pinning `INFISICAL_API_URL`) — see [docker/core/infisical/README.md](docker/core/infisical/README.md).
- Always add new keys to [`docker/.env.example`](docker/.env.example) as **placeholders** (never
  real values), so the variable is discoverable in git.
- **We're heading toward open-sourcing this stack** (todos.md #6). **Scan staged changes for
  secrets before every commit** — client secrets, SMTP creds, private keys, high-entropy tokens.
  Realm/seed files keep `REPLACE_AFTER_IMPORT` placeholders, never real secrets.

## Git & commits
- **One commit per change**, with a clear message. Commit when the change is verified, not before.
- Commits land on **`main`** directly (repo convention). Other sessions/repos push too, so a push
  may be rejected — `git pull --rebase origin main` then push (no merge commits).
- End commit messages with the trailer:
  `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`
- Secret-scan first (above). Don't commit generated host artifacts or large binaries (GGUF/ONNX
  model weights, `.env`, `local-notes/` — all gitignored).

## Verify before "done" — and how to reach the services
We hold a real bar: **prove a change works** (run it, hit the endpoint, read the logs) before
calling it done. Useful facts when testing:
- **LiteLLM `:4000` is NOT published to the host** — it's internal to the docker networks.
  Test via the **public URL** `https://litellm.pdx.sanctioned.tech/v1/...` (host can reach `.pdx`)
  with the **master key** (`LITELLM_MASTER_KEY` in `/opt/homelab/.env`), or `docker exec` inside.
- **unsloth `:8888`** (host LLM) needs the Studio token `UNSLOTH_API_KEY`; LiteLLM holds it, so
  prefer testing chat through LiteLLM.
- For non-trivial API tests, **write a small Python script (stdlib `urllib`/`sqlite3`) to
  `/tmp` on jarvis and run it** — far more reliable than fighting `curl` + nested shell quoting.
  jarvis has `python3` (3.14). On our local Windows shell use **`python3`** (not `python`/`py`).
- Container env at runtime: `docker exec <svc> printenv`. OpenWebUI/etc. with
  `ENABLE_PERSISTENT_CONFIG=False` use **env vars at boot**, but their **Admin Settings UI can
  override values in memory at runtime** (won't persist a restart) — so a live value can differ
  from both the compose env and the stale DB config blob. Check the running value, not just env.

## Editing conventions
- **Keep docs in sync with changes.** Most service dirs have a `README.md`; update it when you
  change that service, and mirror the surrounding style. Update this CLAUDE.md / root README when
  a cross-cutting fact changes. Match the existing tone — terse, rationale-first ("why these
  values"), with the gotchas called out.
- **The full app/service workflow is codified** in [docs/adding-an-app.md](docs/adding-an-app.md)
  (DNS → secrets → DB → compose+Traefik labels → auth → deploy → monitor → verify → commit).
  Follow it for any new service; don't reinvent the steps.
- Pin image versions (no `:latest`/`:main`); GPU containers follow the ComfyUI pattern.

## Authentication — how & when to integrate
Three first-class options behind Traefik + Keycloak; **choose by what the app needs, not by rank:**
- **Native OIDC** — when the app supports OIDC **and must know who the user is** (per-user identity,
  roles/groups, attribution). The app does the login; route stays `secure-chain@file`; needs a
  **per-app Keycloak client + redirect URI + secret**.
- **oauth2-proxy forward-auth** — the **default** when you just need a **login gate** in front of an
  app with no/weak auth. One line: set the router middleware to **`secure-sso@file`** (websockets:
  `sso@file,secure-chain-stream@file`). **No per-app client** (shares the one oauth2-proxy client +
  single callback). Not a lesser fallback — it's the low-friction choice; step up to OIDC only for
  in-app identity.
- **Public** — `secure-chain@file`, only when intentionally unauthenticated and it leaks nothing
  sensitive (e.g. a landing page).

Full decision table, the **native-OIDC recipe**, and secret rotation:
[docker/core/keycloak/README.md](docker/core/keycloak/README.md) → *Integrating a new app*. The
end-to-end onboarding flow is [docs/adding-an-app.md](docs/adding-an-app.md) §6.

## The shared local LLM & its couplings (handle with care)
The host LLM (`unsloth/Qwen3-8B-GGUF`, OpenAI-compatible on `:8888`, fronted by LiteLLM) is a
**shared dependency** across the lab and sibling repos. If you change its **model name**, it
ripples — update **all** of:
- `docker/ai/litellm/config.yaml` (+ README) — the gateway's `model_name`/upstream.
- `docs/kb-manifest.json` `chat_model` → **regenerate** the n8n workflows with
  `python3 docker/ai/n8n/build_kb_workflows.py`, then **redeploy** `kb-chat` to n8n **via the n8n
  API** (PUT the workflow by id + re-activate) — workflows are imported through the API, not
  file mounts. See [docker/ai/n8n/README.md](docker/ai/n8n/README.md).
- LiteLLM **per-app virtual keys** are scoped to model names in LiteLLM's Postgres store —
  re-scope them (`/key/update`) or scoped apps 403 (`key_model_access_denied`).
- The OpenWebUI custom-model row (its DB), and the various READMEs.
- **Sibling repos** `apollo` and `discord-curator` pin the model name too (see below).
Changing only the **context/VRAM** (the unsloth override) does **not** touch the model name, so it
needs none of the above. See [host/unsloth/README.md](host/unsloth/README.md) for the model,
context (native 40,960/slot), q8_0 KV, and VRAM-budget rationale.

## Sibling repos (cross-repo coordination)
Other repos consume this platform: **`apollo`** (voice assistant — uses LiteLLM chat + bge-m3 +
its own scoped key), **`discord-curator`** (n8n flows using the shared master-key credential), and
**`trading-engine`** (files platform-layer asks into `todos.md`). They have **their own Claude Code
sessions**. When a platform change affects them, **leave a clear handoff note in their repo**
(e.g. `MODEL-MIGRATION.md`) rather than editing their configs — let their session apply it. The KB
layer is shared via `docs/kb-manifest.json` (single source of truth for all `kb_*` collections).

---

## Doc index
| Topic | Doc |
|---|---|
| Add a new app/service (full workflow) | [docs/adding-an-app.md](docs/adding-an-app.md) |
| Stack overview, networks, deploy runbook | [docker/README.md](docker/README.md) · [README.md](README.md) |
| Secrets / Infisical (push/pull, gotchas) | [docker/core/infisical/README.md](docker/core/infisical/README.md) |
| Identity / Keycloak / oauth2-proxy SSO | [docker/core/keycloak/README.md](docker/core/keycloak/README.md) |
| Routing / Traefik / middleware chains | [docker/core/traefik/README.md](docker/core/traefik/README.md) |
| Host LLM (unsloth) — model/context/VRAM | [host/unsloth/README.md](host/unsloth/README.md) |
| LLM gateway (LiteLLM) + virtual keys | [docker/ai/litellm/README.md](docker/ai/litellm/README.md) |
| KB library (manifest, n8n flows, access layer) | [docs/kb-standards.md](docs/kb-standards.md) · [docker/ai/n8n/README.md](docker/ai/n8n/README.md) |
| Monitoring / Uptime Kuma | [docker/monitoring/uptime-kuma/README.md](docker/monitoring/uptime-kuma/README.md) |
| Backups (on-host + off-host restic) | [docs/off-host-backup.md](docs/off-host-backup.md) |
| Open backlog + "how we work here" | [todos.md](todos.md) |
