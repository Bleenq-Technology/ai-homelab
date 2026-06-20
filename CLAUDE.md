# ai-homelab-infra — Claude Code working notes

This repo is edited locally and deployed to the host **jarvis** (`ssh Jarvis`,
192.168.2.10, user `sanctioned`). The live tree on the host is **`/opt/homelab`**.
There is **no git on the host** — files get there by being copied up (scp/rsync).

## Shared-dev permissions: fix group-write after every file push

`/opt/homelab` is shared by two developers (`sanctioned` and `jacob`) via the
**`homelab`** group (setgid + default ACLs + `umask 002`). On-host edits inherit
group-write automatically, **but files copied up with `scp` from Windows land as
`0644` (owner-write only)** — scp ignores umask/ACLs and preserves the source mode.
If you don't fix this, the *other* developer can't edit the files you just pushed
without sudo.

We standardize on **`scp`** for transfers (rsync isn't reliably available on our
Windows machines), so the chmod fix-up is a required follow-up step, not optional.

**Rule: after any `scp`/copy of files into `/opt/homelab`, run:**

```bash
ssh Jarvis 'sudo chmod -R g+rwX /opt/homelab'
```

(`g+rwX` = group read/write, and execute/traverse only where already executable —
safe to run over the whole tree; it won't make data files executable.)

> Do **not** widen permissions on secret files. `/opt/homelab/.env` is `640` and the
> `.env*.bak` / `.infisical-auth` files are `600` by design — `g+rwX` leaves their
> group/other bits as-is for the backups (they have no group/other bits to widen),
> and `.env` stays group-read-only. Don't `chmod` those to anything more permissive.

## Secrets

Secrets live in **Infisical** (project `homelab`, env `prod`); `.env` on the host is
a generated artifact pulled via `./pull-secrets.sh`. Never hand-edit `.env` on the
host — add/change secrets with `push-secret.sh`. See `docker/README.md` and
`docker/core/infisical/README.md`.

## Deploy

See `README.md` → "Deploy (summary)" and `docker/README.md` for the full runbook
(docker context, networks, bring-up order).
