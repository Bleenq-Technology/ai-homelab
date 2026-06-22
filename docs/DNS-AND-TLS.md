# DNS & TLS — how it works, and how to adapt it to YOUR network

The stack as-built uses **EasyDNS DNS-01** for certificates and an **EdgeRouter** for LAN name
resolution. You almost certainly have neither — and you don't need them. This doc separates the
two concerns and gives portable options for each.

There are **two independent problems**, and you must solve both:

1. **Certificates** — getting a valid TLS cert for `*.yourdomain` (automatic).
2. **Name resolution** — making `name.yourdomain` actually point at your server (you set this up).

A valid cert with no resolution = nothing loads. Resolution with no cert = browser warnings. You
need both.

---

## 1. Certificates (TLS) — the DNS-01 wildcard

Traefik issues **one wildcard cert** for `*.yourdomain` from Let's Encrypt using an ACME
**DNS-01** challenge: it proves control of the domain by writing a temporary `TXT` record via your
**DNS provider's API**. Consequences:

- **Port 80 does NOT need to be internet-reachable.** The server only needs **outbound** access to
  the provider's API. This is why the whole thing works behind a home NAT with no inbound ports.
- It's the only ACME method that can issue a **wildcard**, so every service shares one cert with no
  per-service config.

### Using the default provider (EasyDNS)

Put your API credentials in Docker secret files (see
[DEPLOY.md → step 4](../DEPLOY.md#easydns--dns-provider-secret-files-both-paths)):
`secrets/easydns_token`, `secrets/easydns_key` (created with `printf`, no trailing newline,
`chmod 600`). Traefik reads them via lego's `_FILE` convention.

### Switching to a different DNS provider (Cloudflare, Route 53, deSEC, …)

Traefik/lego supports [dozens of providers](https://doc.traefik.io/traefik/https/acme/#providers).
To switch:

1. In `docker/core/traefik/` (the Traefik static config / compose env), change the
   **certResolver's `dnsChallenge.provider`** from `easydns` to your provider's lego code
   (e.g. `cloudflare`, `route53`, `desec`).
2. Replace the EasyDNS env/secret references with **your provider's required variables** (each
   provider documents its own — e.g. Cloudflare uses `CF_DNS_API_TOKEN`, Route 53 uses AWS creds).
   Keep using the Docker-secret `_FILE` form where the provider supports it; otherwise set them as
   env from your `.env`.
3. Drop the now-unused `secrets/easydns_*` files.

The rest of the stack is provider-agnostic — only Traefik's resolver block changes.

### If you can't/won't use DNS-01 at all

Alternatives (each a bigger change):
- **HTTP-01 challenge** — switch the resolver to `httpChallenge` and expose port 80 inbound. **Loses
  the wildcard** (you'd need a cert per hostname or a SAN list), so it's a poorer fit here.
- **Your own/internal CA or a self-signed wildcard** — fine for a closed LAN; you'll install the CA
  on client devices. Point Traefik at the cert/key files instead of an ACME resolver.

---

## 2. Name resolution — making `*.yourdomain` point at the server

Cert issuance never routes traffic. Something must answer "what IP is `grafana.yourdomain`?" with
your server's address. Pick whichever fits your setup — **you do not need our router.**

| Your situation | Do this |
|---|---|
| **LAN-only access, simplest** | Add a DNS **rewrite/override** mapping `*.yourdomain` (or each `name.yourdomain`) → server LAN IP on whatever does DNS for your LAN. The stack **includes AdGuard Home** — use its *DNS rewrites* (`*.yourdomain` → server IP) and point your devices/router at AdGuard. Pi-hole, your router's local-DNS, or dnsmasq work identically. |
| **Just want to test from one machine** | Add lines to that machine's `/etc/hosts` (Windows: `C:\Windows\System32\drivers\etc\hosts`): `192.168.x.x  grafana.yourdomain keycloak.yourdomain …`. No wildcards in hosts files, so list the names you'll hit. |
| **You want it reachable from the internet** | Create **public DNS records** at your registrar/DNS host: a wildcard `*.yourdomain A → your public IP` (or per-host records), and forward `443` (and `53`/others only if needed) to the server. Cert issuance still uses DNS-01, so you don't need port 80. |
| **Split-horizon (both)** | Public records for outside + a LAN rewrite so internal clients resolve to the private IP directly. Optional; nice-to-have. |

> The maintainers' EdgeRouter just does the "LAN DNS rewrite" job in the first row, plus a dynamic-IP
> updater (`ddns-easydns.sh`) for a residential WAN. If your IP is static, or you're LAN-only, you
> can ignore both `ddns-easydns.sh` and `sync-firewall-cert.sh` entirely (see
> [MUST-CHANGE.md](MUST-CHANGE.md)).

---

## Sanity check

After both are set:

```bash
# resolution: should return your server IP
nslookup grafana.yourdomain
# cert: should show a valid Let's Encrypt wildcard, no warning
curl -vI https://grafana.yourdomain 2>&1 | grep -Ei 'subject|issuer|HTTP'
```

If resolution is right but the cert is missing/invalid, watch `docker compose logs -f traefik`
during startup for DNS-01 errors (bad API creds, a trailing newline in the secret files, or no
outbound access to the provider API).
