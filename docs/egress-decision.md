# Shadow-AI egress: detect, don't IP-block — the decision

**Verdict (2026-07-22):** The gateway chokepoint is enforced *inbound* (nothing reaches a model without
a scoped key) and *for the host LLM* (unsloth is Docker+localhost only, #39). For **container egress to
cloud LLM providers**, we **detect and alert, and deliberately do NOT attempt IP-level blocking.** The
real block — an SNI-filtering egress proxy — is filed as #39b for if it's ever mandated.

This is the reasoned close of `todos.md` #39's "block second" half.

---

## Why not just block the provider IPs

The obvious move — drop traffic from the Docker subnets to `api.openai.com`, `api.anthropic.com`, etc.
— **does not work cleanly on this topology, and risks taking down legitimate services.** Evidence,
resolved live 2026-07-22:

| Provider | Resolves to | Owner |
|---|---|---|
| `api.anthropic.com` | `160.79.104.10` | Anthropic's **own** range — blockable cleanly |
| `api.openai.com` | `162.159.140.245`, `172.66.0.243` | **Cloudflare shared anycast** |
| `api.groq.com` · `api.mistral.ai` · `api.together.xyz` · `openrouter.ai` | `104.18.x` · `162.159.x` · `172.64/66.x` | **Cloudflare shared anycast** |
| `generativelanguage.googleapis.com` | `172.217.x` | **Google shared** (all Google APIs) |

**Most providers sit behind Cloudflare's (or Google's) shared anycast IPs.** A single IP like
`162.159.140.245` serves `api.openai.com` *and thousands of other Cloudflare-hosted sites* — Cloudflare
routes by TLS **SNI**, not by IP. So an `iptables -d 162.159.140.245 -j DROP` rule blocks not "OpenAI"
but **every Cloudflare site on that IP** — which the platform's legitimate web consumers hit constantly:

- **searxng** is a web *search engine* — it fetches arbitrary sites, many Cloudflare-fronted.
- **n8n** fetches arbitrary URLs (Tavily, KB-ingest source pages).
- the **cloudflared** tunnels and **comfyui** model downloads also touch shared CDN ranges.

So IP-blocking CDN-fronted providers isn't merely *evadable* (IP rotation) — it's an **availability
risk to legitimate traffic, including the live public-chat tunnels.** Markets a governance gap for an
outage risk is the wrong trade. (The one provider on a dedicated range, Anthropic, could be blocked
collateral-free — but blocking one provider while five others stay reachable on un-blockable shared IPs
is incoherent coverage, not a control.)

## Why detect-and-alert is proportionate here

The threat #39 targets is **shadow AI** — a container reaching a frontier model outside the gateway,
untraced. On this platform that threat is already contained by a stack of controls, none of which is
IP-blocking:

1. **No cloud provider is configured anywhere.** LiteLLM routes only to local `unsloth` (`:8888`) and
   `bge-m3` — verified. Nothing on the platform *has* a reason to reach a cloud provider, and no cloud
   API key is issued to any container. Shadow AI here would require someone deliberately adding a key.
2. **Detection ships and alerts.** `check-egress.sh` (weekly) probes every provider path and reads
   AdGuard's DNS log — which is **hostname-accurate** (it sees `api.openai.com`, not just an IP), the
   exact thing IP-rules can't be. It publishes to Prometheus with a dead-man.
3. **Policy names it.** [`ai-acceptable-use.md`](ai-acceptable-use.md) rule 1: every model call goes
   through the gateway; a cloud key in a container env is a violation. Rule 5: sensitive content stays
   local.
4. **The inventory would catch a new consumer.** A system that started emitting cloud-provider traffic
   without an inventory entry is exactly what the AI-BOM drift check flags.

For a two-person homelab with **no cloud provider in the loop**, that is the proportionate control set.
Forcing all `ai`-network egress through a filtering proxy — the only thing that would truly *block* —
is a real system with real breakage surface, and building it to defend a threat that is already
detected, policy-covered, and not currently reachable would be controls-for-their-own-sake.

## The honest gap, and when to close it

What we **cannot** currently do: *prevent* a determined or careless insider from putting a cloud key in
a container and reaching a provider on a shared CDN IP before the weekly detection notices. Detection is
after-the-fact (up to a week) and hostname-accurate but **not per-container attributed** (AdGuard sees
the host resolver, not the container).

**Close it — [#39b, filed] — when any of these becomes true:**

1. **A cloud provider is added to LiteLLM.** The moment real provider traffic is legitimate, "block
   everything else to that provider" becomes both meaningful and necessary, and the proxy is worth it.
2. **A second person or an untrusted workload** gets container-deploy rights (the insider threat stops
   being hypothetical).
3. **A compliance requirement** demands demonstrable egress prevention, not detection.

**The mechanism when it's time:** a per-`ai`-network **SNI-filtering egress proxy** (e.g. a small
`sni-proxy`/`squid`-with-`ssl_bump-peek` or a dedicated resolver+proxy) that `ai` containers must route
through, allowing by **hostname** (so it distinguishes `api.openai.com` from another Cloudflare site on
the same IP — the thing IP-rules fundamentally can't) and denying provider hostnames except from
LiteLLM. That is the "per-network egress proxy" the governance doc named; it's a scoped project, not a
config change, which is precisely why it waits for a trigger.

---

*Related: the gateway *choice* decision is [`gateway-decision.md`](gateway-decision.md); the standing
position is [`ai-governance.md`](ai-governance.md) (§5, third-party & shadow AI).*
