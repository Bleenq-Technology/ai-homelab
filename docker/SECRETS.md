# Secrets — how to add/change them (read before touching `.env`)

The homelab stack on **Jarvis** runs from a single shared `/opt/homelab/.env`. That
file is **generated**, not hand-maintained:

```
Infisical (prod)  ──pull-secrets.sh──►  /opt/homelab/.env  ──compose──►  containers
   (source of truth)                       (disposable)
```

`pull-secrets.sh` runs `infisical export > .env`, which **truncates `.env` first**.
So:

> ⚠️ **Anything added to `.env` but not to Infisical is silently lost** on the next
> `pull-secrets.sh` / deploy. Never hand-edit `.env` to add a secret.

This is exactly what bit `discord-curator`: its values were written to `.env` only,
then wiped on a re-pull. The two scripts below are the read/write pair that make this
a non-issue.

| Script | Direction | What it does |
|---|---|---|
| `pull-secrets.sh` | Infisical → `.env` | rebuild the whole `.env` from Infisical |
| `push-secret.sh`  | value → Infisical | set/rotate ONE secret in Infisical (durable) |

## Adding or changing a secret

```bash
cd /opt/homelab
./push-secret.sh DISCORD_CURATOR_DB_PASSWORD 's3cr3t-value'   # -> Infisical (durable)
#   or:  ./push-secret.sh KEY            # reads the value from the current ./.env
./pull-secrets.sh                                              # sync it into .env
docker compose -f compose.yml up -d <service>                 # recreate the consumer
```

`push-secret.sh` writes to **Infisical only** (and never prints the value — it
reads back to verify and reports the length). It does **not** touch `.env`; run
`pull-secrets.sh` to bring the new value into `.env`. That ordering keeps Infisical
the single source of truth.

The whole rule: **secrets go in via `push-secret.sh`** (→ Infisical), never straight
into `.env`.

## For coding projects / agents adding a new service

When a new service needs a secret (DB password, API token, bot token, etc.):

1. Generate the value.
2. `./push-secret.sh <KEY> '<value>'` on Jarvis — puts it in Infisical (durable).
3. `./pull-secrets.sh` to sync `.env`, reference it in compose as `${<KEY>}`, and
   recreate the service.
4. Add the key (with a placeholder, **never the real value**) to
   [`.env.example`](.env.example) so the variable is discoverable in git.
5. In Infisical, add a short **note/description** on the secret (what it's for, which
   service) via the Infisical UI — future-you will thank you.

Do **not** commit real secret values to git. Realm/client secrets in
`core/keycloak/realm-homelab.json` are intentionally `REPLACE_AFTER_IMPORT`.

## Recovering / auditing

- Regenerate `.env` from Infisical: `./pull-secrets.sh` (safe — everything lives in
  Infisical). Timestamped `.env.bak.*` snapshots are kept as a safety net.
- Check a key everywhere:
  ```bash
  grep '^KEY=' .env                                            # live .env
  ./push-secret.sh KEY "$(grep '^KEY=' .env | cut -d= -f2-)"   # (re)assert into Infisical
  infisical secrets get KEY --plain ...                        # read Infisical directly
  ```
- Keycloak client secrets specifically: Keycloak is the source of truth — see
  [`core/keycloak/README.md`](core/keycloak/README.md) (§ Secrets & admin pipeline)
  and `core/keycloak/sync-oidc-secrets.sh`.
