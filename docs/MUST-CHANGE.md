# Must change for YOUR environment

Everything in this repo is configured for the maintainers' environment. This is the single
checklist of values that are **ours** and must become **yours** before (or as) you deploy. Pair it
with [`docker/.env.example`](../docker/.env.example) (every variable, annotated) and the
[DEPLOY guide](../DEPLOY.md).

Legend: **🔴 required** · **🟡 required if you use that feature** · **⚪ cosmetic/optional**

## Identity of your deployment

| Value | Ours (example) | Where it appears | |
|---|---|---|---|
| `DOMAIN` | `pdx.sanctioned.tech` | `.env`; referenced by every service's `Host()` rule | 🔴 |
| `ACME_EMAIL` | `paul.vilevac@bleenq.com` | `.env` (Let's Encrypt expiry notices) | 🔴 |
| `TZ` | `America/Los_Angeles` | `.env` | ⚪ |
| SSH host alias / `/opt/homelab` path | `Jarvis`, `/opt/homelab` | your `~/.ssh/config`, the deploy commands | 🔴 |
| Hostname references | `jarvis` | `OLLAMA_BASE_URL=http://jarvis:11434`, docs | 🟡 |

## DNS, TLS, and network

| Value | Ours | Notes | |
|---|---|---|---|
| DNS provider + API creds | EasyDNS (`secrets/easydns_token`,`easydns_key`) | For the wildcard DNS-01 cert. Swap provider per [DNS-AND-TLS.md](DNS-AND-TLS.md) | 🔴 |
| LAN IP the stack binds/advertises | `192.168.2.10` | `HOST_LAN_IP` and `ADGUARD_DNS_IP` in `.env` (also appears in compose/scripts) | 🔴 |
| LAN name resolution for `*.DOMAIN` | EdgeRouter static-host-mapping | You likely **don't** have our router — pick any method in [DNS-AND-TLS.md](DNS-AND-TLS.md) | 🔴 |

## External service credentials

| Value | Service | | |
|---|---|---|---|
| `SMTP_HOST/PORT/USER/PASSWORD/FROM` | Mailjet (or any SMTP). `SMTP_FROM` must be a **verified sender** | 🟡 (email flows) |
| `TAVILY_API_KEY` | Tavily web search (SearXNG is the fallback) | 🟡 |
| `DISCORD_WEBHOOK_URL` | Alert delivery (Alertmanager, Uptime Kuma) | 🟡 |
| `DISCORD_BOT_TOKEN` | Only for the separate `discord-curator` project | ⚪ |

## Every secret/password

All `change_me_*`, `set_from_keycloak`, `*_from_*`, and the Traefik hash are placeholders — **change
all of them.** Quick generators:

| Kind | Command |
|---|---|
| 64-char hex (encryption keys: `HOMARR_SECRET_ENCRYPTION_KEY`, `LANGFUSE_ENCRYPTION_KEY`, …) | `openssl rand -hex 32` |
| base64 secret (`OAUTH2_PROXY_COOKIE_SECRET`, salts, …) | `openssl rand -base64 32` |
| strong password (DB roles, admin logins) | `openssl rand -base64 24` |
| Traefik dashboard `TRAEFIK_DASHBOARD_AUTH` | `htpasswd -nbB admin 'pass'` then **double every `$` → `$$`** in `.env` |
| OIDC client secrets (`*_OIDC_CLIENT_SECRET`, `OAUTH2_PROXY_CLIENT_SECRET`) | generated **in Keycloak** per client, then pushed to your secret store |

## Environment-specific scripts you can ignore or adapt

These automate the maintainers' **EdgeRouter + EasyDNS** setup. If you don't run that exact gear,
you don't need them — they won't run as-is:

| Script | Hardcoded to | If it's not yours |
|---|---|---|
| `docker/ddns-easydns.sh` | EasyDNS `RECORD_ID`, the `firewall.pdx` record | Only needed for a *dynamic* residential WAN IP on EasyDNS. Skip if your IP is static or your provider differs. |
| `docker/core/traefik/sync-firewall-cert.sh` | firewall `192.168.2.1`, an SSH key path | Pushes the wildcard cert to an EdgeRouter GUI. Not needed without one. |

## GPU

| If you have… | Do |
|---|---|
| No GPU | Skip `host/unsloth/` and don't start `comfyui` / `wyoming-piper` / `wyoming-faster-whisper` / `bge-m3`; point LiteLLM at a cloud model (see [DEPLOY.md → GPU](../DEPLOY.md#gpu--the-host-llm)) |
| A different GPU | Adjust the model/VRAM in `host/unsloth/` and the GPU service tags |

> Note: the `.env.example` still lists `FIREZONE_*` variables; Firezone was retired in favor of
> WireGuard on the router and those vars are unused — safe to ignore.
