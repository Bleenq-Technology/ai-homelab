# Infisical from scratch (cold-start bootstrap)

The maintainers run **[Infisical](https://infisical.com)** as the single source of truth for all
~54 stack secrets. At deploy time `/opt/homelab/.env` is **regenerated from Infisical** by
[`pull-secrets.sh`](../docker/pull-secrets.sh) — it is a *generated artifact*, never the source.

This is great once it exists, but it has a genuine **chicken-and-egg**: Infisical itself runs
*inside* this stack, and its own database needs secrets to start. This guide is the cold start
**with nothing in hand** — no existing vault, no `.infisical-auth`, no backup.

> If you'd rather not run Infisical at all, you don't have to — use the **manual `.env`** path in
> [DEPLOY.md → Secrets, Path A](../DEPLOY.md#path-a--manual-env-simplest-great-for-a-first-boot-or-a-small-deployment).
> Come here when you want the source-of-truth model.

> ⚠️ **The one trap to internalize first:** `pull-secrets.sh` **truncates and regenerates `.env`**
> from Infisical. Until Infisical actually holds your secrets, running it will **wipe** a
> hand-built `.env`. Do every step below *before* you ever run `pull-secrets.sh`.

---

## Phase A — break the chicken-and-egg with a minimal manual `.env`

Infisical can't serve secrets until its own Postgres/Redis/service are up, and those need a few
secrets. So you start with a tiny hand-written `.env` containing only the **bootstrap set**:

```bash
# on the server, in /opt/homelab
cp .env.example .env       # then trim/fill — at minimum set these real values:
```

| Variable | Why it's bootstrap (can't come from Infisical) |
|---|---|
| `POSTGRES_SUPERUSER`, `POSTGRES_PASSWORD` | Infisical's database must come up first |
| `REDIS_PASSWORD` | Infisical's cache |
| `INFISICAL_DB_PASSWORD` | the `infisical` Postgres role |
| `INFISICAL_ENCRYPTION_KEY` | **decrypts Infisical's stored secrets** — lose it and the vault is unrecoverable |
| `INFISICAL_AUTH_SECRET` | required to start the Infisical service |
| `DOMAIN`, `ACME_EMAIL` | so Traefik can route + cert `infisical.DOMAIN` |

Generate strong values (`openssl rand -hex 32` / `-base64 32`). Also create the DNS-provider
secret files (`secrets/easydns_*`) per [DEPLOY.md → step 4](../DEPLOY.md#easydns--dns-provider-secret-files-both-paths).

Bring up just enough to get Infisical online:

```bash
for n in proxy data ai monitoring; do docker network create "$n" 2>/dev/null || true; done
docker compose -f compose.yml up -d postgres redis infisical traefik
docker compose -f compose.yml logs -f traefik     # wait for the wildcard cert
```

Open `https://infisical.DOMAIN` — the **first visit creates the admin account**.

---

## Phase B — create the project, environment, and a machine identity

In the Infisical UI:

1. **Create a project** named `homelab`.
2. Ensure it has an environment **`prod`** (Infisical creates dev/staging/prod by default).
3. Create a **Machine Identity** (Universal Auth) — call it `jarvis-deploy` — and **grant it
   read + write** on `homelab/prod`. Copy its **Client ID** and **Client Secret**.
4. Note the project's **Project ID** (Project → Settings).

Write the machine-identity credentials to `/opt/homelab/.infisical-auth` (this file is gitignored
and kept out of Infisical — it's how the scripts authenticate). The scripts `source` it, so it's
shell-`KEY=value` form:

```bash
# /opt/homelab/.infisical-auth   (chmod 600)
INFISICAL_DOMAIN=https://infisical.yourdomain/api
INFISICAL_PROJECT_ID=<project id>
INFISICAL_ENV=prod
INFISICAL_CLIENT_ID=<machine identity client id>
INFISICAL_CLIENT_SECRET=<machine identity client secret>
```
```bash
chmod 600 /opt/homelab/.infisical-auth
```

> `INFISICAL_DOMAIN` points at your self-hosted API (note the `/api` suffix). The five field names
> above are exactly what [`pull-secrets.sh`](../docker/pull-secrets.sh) /
> [`push-secret.sh`](../docker/push-secret.sh) expect.

---

## Phase C — load your secrets, then switch `.env` to "generated"

Now put every real secret into Infisical. Two ways:

**Bulk, from your filled-in `.env`:** finish populating `.env` (Path A) with all real values, then
push each one up with the write helper:

```bash
# on the server, in /opt/homelab — push every KEY in .env into homelab/prod
grep -E '^[A-Za-z_][A-Za-z0-9_]*=' .env | cut -d= -f1 | while read -r KEY; do
  ./push-secret.sh "$KEY"      # reads KEY's value from ./.env, sets it in Infisical
done
```
`push-secret.sh` never prints values (only their length), and verifies each with a read-back.

**Or by hand:** add each variable in the Infisical UI under `homelab/prod`.

Then prove the round-trip and switch over:

```bash
./pull-secrets.sh        # regenerates .env FROM Infisical — should report ~54 secrets
docker compose -f compose.yml up -d
```

From now on, `.env` is disposable. To add or rotate a secret:

```bash
./push-secret.sh SOME_KEY 'new value'     # write to Infisical (source of truth)
./pull-secrets.sh                          # regenerate .env
docker compose -f compose.yml up -d some-service   # recreate to apply
```

**Never hand-edit `.env` on the server again** — the next `pull-secrets.sh` would drop the change.
(That's literally how a key got emptied once before it was pushed.)

---

## Keep these out-of-band (the only things NOT in Infisical)

Store these in a password manager — they're needed *before* Infisical can serve anything, so they
can't live in it:

- the machine-identity **Client ID / Client Secret** (in `.infisical-auth`)
- `INFISICAL_ENCRYPTION_KEY` (decrypts the vault), `INFISICAL_AUTH_SECRET`, `INFISICAL_DB_PASSWORD`
- `POSTGRES_SUPERUSER` / `POSTGRES_PASSWORD`, `REDIS_PASSWORD`
- the DNS-provider API token/key (also Docker secret files)
- a **backup of the `infisical` Postgres database** (the encrypted store)

**Backup + `INFISICAL_ENCRYPTION_KEY` together = restorable. Either one alone is useless.** That
pairing is your disaster-recovery story; the per-instance recovery runbook is in
[docker/core/infisical/README.md](../docker/core/infisical/README.md).
