# Deploying ai-homelab-infra on a fresh host

This guide takes you from a **bare Linux host** to the full stack running behind TLS. It is
written for someone who has *not* seen this repo before. If you just want orientation, read the
[README](README.md) first; come back here to actually deploy.

> **Mental model (read this once):** you edit this repo on your **workstation**, and you deploy by
> **copying files to the server** — you do **not** `git clone` on the server. See
> [The deploy model](#3-the-deploy-model-repo--server) below. It's the single most important
> non-obvious thing here.

There are four supporting docs this one links to:
- **[docs/MUST-CHANGE.md](docs/MUST-CHANGE.md)** — every value that is *ours* and must become *yours*.
- **[docs/INFISICAL-BOOTSTRAP.md](docs/INFISICAL-BOOTSTRAP.md)** — standing up the secret store from nothing.
- **[docs/DNS-AND-TLS.md](docs/DNS-AND-TLS.md)** — making `*.yourdomain` resolve and get certs, with or without our exact setup.
- **[docker/.env.example](docker/.env.example)** — the annotated list of every variable.

---

## 0. Before you start — external accounts to create

The stack composes a few free third-party services. Create these up front; you'll paste their
credentials into your secrets later. Only the **DNS provider** is effectively required for the
default TLS path — the rest degrade gracefully.

| Service | What it's for | Free tier | Required? |
|---|---|---|---|
| **A DNS provider with an API** (we use [EasyDNS](https://easydns.com); [Cloudflare](https://www.cloudflare.com), [Route 53](https://aws.amazon.com/route53/), DigitalOcean, deSEC, etc. all work) | Issues the **wildcard TLS cert** via an ACME **DNS-01** challenge, and (optionally) hosts your domain's public records | Cloudflare/deSEC are free; EasyDNS/Route53 are paid-but-cheap | **Yes** (or switch to a different cert method — see [DNS-AND-TLS.md](docs/DNS-AND-TLS.md)) |
| A **domain name** | Everything is served at `*.yourdomain` | ~$10/yr | **Yes** |
| [**Tavily**](https://tavily.com) | Web search for Open WebUI / RAG (LLM-optimized) | Free dev tier (~1k req/mo) | No — SearXNG (self-hosted, included) is the fallback |
| [**Mailjet**](https://www.mailjet.com) | Outbound email: password resets, email verification, alerts (Keycloak, Grafana, NetBox, Baserow) | Free (~6k emails/mo) | No — but several "reset/verify" flows need *some* SMTP |
| [**Discord**](https://discord.com) (a webhook, + optionally a bot token) | Alert delivery (Prometheus/Alertmanager, Uptime Kuma); the bot token is only for the separate `discord-curator` project | Free | No |
| **Google / LinkedIn OAuth app** | Optional *social login* brokered through Keycloak | Free | No |

> Don't have a GPU? You can still run most of the stack — see [GPU & host LLM](#gpu--the-host-llm)
> for what to drop.

---

## 1. Prerequisites (on the server)

A 64-bit Linux host (we run **Ubuntu**). For the full stack budget ~32 GB RAM and plenty of disk;
a smaller subset runs comfortably on less.

```bash
# Docker Engine + Compose v2 plugin (official convenience script)
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker "$USER"   # log out/in afterward
docker compose version            # must be v2.x

# Tools the runbooks use
sudo apt-get update
sudo apt-get install -y apache2-utils openssl python3   # htpasswd, openssl, python3

# (GPU hosts only) NVIDIA Container Toolkit — for comfyui / wyoming / bge-m3 / host LLM
# Follow https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html
# then verify:
docker run --rm --gpus all nvidia/cuda:12.4.0-base-ubuntu22.04 nvidia-smi
```

**On your workstation** (where you edit the repo and drive deploys):

```bash
git clone https://github.com/Bleenq-Technology/<repo>.git
cd <repo>
# Install the Infisical CLI (only if you'll use Infisical for secrets — see step 4):
#   https://infisical.com/docs/cli/overview
```

---

## 2. Connect to the server with a Docker context

You drive Docker on the server over SSH from your workstation. Set up an SSH key + host alias,
then create a Docker context (this `create` step is the one people miss):

```bash
# ~/.ssh/config on your workstation
# Host myserver
#   HostName 192.168.x.x        # or a DNS name
#   User youruser

docker context create myserver --docker "host=ssh://myserver"
docker context use myserver
docker info     # should now show the server's Docker
```

From here, every `docker ...` command targets the server. (You can also prefix individual
commands with `docker --context myserver ...`.)

---

## 3. The deploy model (repo → server)

**This repo's `docker/` directory is the source of truth. The server runs a *copy* of it at
`/opt/homelab` — there is no git on the server.** You deploy by copying files up.

- `/opt/homelab` **mirrors `docker/`** with the `docker/` prefix dropped:
  `docker/ai/litellm/config.yaml` → `/opt/homelab/ai/litellm/config.yaml`. Host-level (non-Docker)
  services live under the repo's `host/`.
- **First time:** seed the whole tree once (this is the *only* time a bulk copy is right — before a
  real `.env` exists to clobber):
  ```bash
  ssh myserver 'sudo mkdir -p /opt/homelab && sudo chown -R "$USER":"$USER" /opt/homelab'
  scp -r docker/* myserver:/opt/homelab/
  ```
- **Every change after that:** copy only the **individual changed file(s)** to the matching path.
  **Never sync/rsync the whole tree afterward** — it would clobber the host-local `.env` and other
  generated files.
- **After any copy, fix group-write** (so a second admin can edit without sudo; safe over the tree,
  and it leaves `600`/`640` secret files alone):
  ```bash
  ssh myserver 'sudo chmod -R g+rwX /opt/homelab'
  ```
- **Apply changes by recreating** the service via the **aggregate** compose file (project `homelab`):
  ```bash
  ssh myserver 'cd /opt/homelab && docker compose -f compose.yml up -d <service>'
  ```
  Always use the root `compose.yml` (it `include:`s the four layers) — driving a single layer file
  directly causes container-name collisions.

> If you'd rather keep it simple for a single-admin deployment, you *can* run the stack straight
> from a `git clone` on the server — just know that `/opt/homelab` + scp is the model the rest of
> the docs assume, and the group-write/`.env`-clobber rules exist because of it.

---

## 4. Secrets — pick one of two paths

Every password ships as a placeholder in [`docker/.env.example`](docker/.env.example). The live
`.env` lives **only on the server** (gitignored). You have two ways to manage it:

### Path A — Manual `.env` (simplest; great for a first boot or a small deployment)

```bash
# on the server, in /opt/homelab
cp .env.example .env
# edit .env: set DOMAIN, ACME_EMAIL, and replace EVERY change_me_* / set_from_* value.
# generate strong values where noted, e.g.:
openssl rand -hex 32         # 64-char hex (encryption keys)
openssl rand -base64 32      # base64 secrets
htpasswd -nbB admin 'pass'   # TRAEFIK_DASHBOARD_AUTH (then double every $ -> $$ in .env)
```
See **[docs/MUST-CHANGE.md](docs/MUST-CHANGE.md)** for exactly which values to change and how to
generate each.

> ⚠️ **Trap:** if you later adopt Infisical, **do not run `./pull-secrets.sh` while using a manual
> `.env`** — it **truncates and regenerates** `.env` from Infisical and will silently wipe your
> hand-entered values. Manual `.env` and Infisical are an either/or until Infisical is fully loaded.

### Path B — Infisical (the source-of-truth model the maintainers run)

Secrets live in a self-hosted Infisical vault; `.env` becomes a generated artifact. This has a
genuine chicken-and-egg (Infisical runs *inside* the stack), so it has its own guide:
**→ [docs/INFISICAL-BOOTSTRAP.md](docs/INFISICAL-BOOTSTRAP.md)** (empty vault → project → machine
identity → load secrets → `pull-secrets.sh`).

### EasyDNS / DNS-provider secret files (both paths)

The wildcard cert's DNS-01 challenge needs your DNS provider's API credentials as **Docker secret
files** (not in `.env`). For the default EasyDNS resolver:

```bash
cd /opt/homelab/secrets
printf '%s' 'YOUR_DNS_API_TOKEN' > easydns_token   # printf, NOT echo — a trailing \n breaks auth
printf '%s' 'YOUR_DNS_API_KEY'   > easydns_key
chmod 600 easydns_token easydns_key
```
Using a different DNS provider (Cloudflare, Route 53, …)? See **[docs/DNS-AND-TLS.md](docs/DNS-AND-TLS.md)**
to swap the Traefik certResolver and secret env names.

---

## 5. DNS + TLS

Two separate things, both needed:

1. **Cert issuance** (automatic, via DNS-01): Traefik proves domain ownership by writing a TXT
   record through your DNS provider's API — so **port 80 does not need to be internet-reachable**,
   the server only needs **outbound** access to the provider's API. One wildcard cert covers
   `*.yourdomain`.
2. **Name resolution** (you set this up): something must resolve `*.yourdomain` (or per-service
   `name.yourdomain`) to the server's IP, or the browser can't reach the services even with a valid
   cert.

How you do #2 depends on your network — public A records, a LAN DNS rewrite (Pi-hole / the included
AdGuard / your router), or `/etc/hosts`. **We don't assume you have our firewall or its DNS.**
**→ [docs/DNS-AND-TLS.md](docs/DNS-AND-TLS.md)** covers every option, including swapping DNS
providers and skipping the router entirely.

---

## 6. Create the networks and bring it up

```bash
# (targeting the server via your docker context, or run on the server in /opt/homelab)

# 1. shared external networks (once)
for n in proxy data ai monitoring; do docker network create "$n" 2>/dev/null || true; done

# 2. data layer first, so Postgres/Redis/MinIO are ready for their consumers
docker compose -f compose.yml up -d postgres redis minio minio-init clickhouse

# 3. start small — verify TLS works before the whole zoo (recommended)
docker compose -f compose.yml up -d traefik keycloak infisical
docker compose -f compose.yml logs -f traefik     # watch the wildcard cert get issued
#   then open https://traefik.yourdomain/dashboard/ — a valid cert means DNS-01 worked.

# 4. bring up the rest
docker compose -f compose.yml up -d
```

**Postgres provisions one database + least-privilege role per service on first boot**, so the
order above matters only in that the data layer should be healthy first.

Published host ports to be aware of: `80/443` (Traefik), `53` (AdGuard DNS), `7687` (Neo4j Bolt),
`10200`/`10300` (Wyoming TTS/STT), `3000` (AdGuard first-run wizard — can be closed after).

---

## 7. First-run configuration

- **Keycloak** (`https://keycloak.yourdomain`): log in with `KEYCLOAK_ADMIN` /
  `KEYCLOAK_ADMIN_PASSWORD`. The `homelab` realm is seeded from
  `docker/core/keycloak/realm-homelab.json`; per-app OIDC client secrets are placeholders
  (`set_from_keycloak`) — generate each client's secret in Keycloak, then set it with
  `push-secret.sh` (Path B) or in `.env` (Path A) and recreate the app. See
  [docker/core/keycloak/README.md](docker/core/keycloak/README.md).
- **Infisical** (`https://infisical.yourdomain`): first visit creates the admin account.
- **AdGuard** (`http://server:3000` first run): set its admin in the wizard.
- **Grafana / Open WebUI / Portainer / Langfuse**: log in via Keycloak SSO once their OIDC client
  secrets are set; until then use the local-admin fallback where the service offers one.

---

## GPU & the host LLM

The local LLM is **not** a container — it's a host **systemd** service (`host/unsloth/`,
llama.cpp serving an OpenAI-compatible API on `:8888`, fronted by LiteLLM). The GPU-dependent
**containers** are `comfyui`, `wyoming-piper`, `wyoming-faster-whisper`, and `bge-m3`.

**No GPU?** The platform (edge, identity, data, monitoring, most AI tooling) still runs. Either
don't start the GPU services, or point LiteLLM at a cloud model instead of the host LLM:
- skip `host/unsloth/` entirely, and
- omit `comfyui` / `wyoming-piper` / `wyoming-faster-whisper` / `bge-m3` from your `up -d`, and
- in `docker/ai/litellm/config.yaml`, point the gateway at a hosted model (OpenAI/Anthropic/etc.)
  so Open WebUI still has a chat backend.

See [host/unsloth/README.md](host/unsloth/README.md) for the model, context, and VRAM rationale.

---

## Troubleshooting

- **Cert never issues / Traefik logs show DNS-01 errors:** wrong/insufficient DNS API permissions,
  a trailing newline in `secrets/easydns_*` (use `printf`, not `echo`), or the server can't reach
  the provider API. See [docs/DNS-AND-TLS.md](docs/DNS-AND-TLS.md).
- **`docker context use` fails:** you skipped `docker context create` (step 2) or SSH isn't working.
- **A service starts then dies referencing a missing var:** that secret is still a placeholder —
  check `.env` against [docs/MUST-CHANGE.md](docs/MUST-CHANGE.md).
- **`name already in use` on `up`:** you drove a single layer file instead of the aggregate
  `compose.yml` (step 3 of the deploy model).
- **GPU service won't start:** NVIDIA Container Toolkit not installed/configured, or no GPU — see
  [GPU & the host LLM](#gpu--the-host-llm).

---

Once it's up, the [README](README.md) service table tells you what each component does and how it's
authenticated. To add your *own* service the way the maintainers do, follow
[docs/adding-an-app.md](docs/adding-an-app.md).
