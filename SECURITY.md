# Security Policy

## Reporting a vulnerability

Please **do not** open a public GitHub issue for security vulnerabilities.

Report privately via either:

1. **GitHub private vulnerability reporting** — the **Security** tab → **Report a vulnerability**
   (preferred; keeps the report and discussion private until a fix is ready), or
2. **Email** — `security@bleenq.com` (or `paul.vilevac@bleenq.com`).

Please include:

- a description of the issue and its impact,
- the affected component / file(s) and version or commit,
- steps to reproduce or a proof of concept, and
- any suggested remediation.

We'll acknowledge within a few business days, keep you updated on progress, and credit you in the
fix (unless you prefer to remain anonymous). Please give us reasonable time to remediate before
any public disclosure.

## Scope and expectations

This is an open **reference architecture** for a self-hosted platform, not a hosted service.
Some important context for reporters and adopters:

- **You own your deployment.** The committed configuration uses placeholder secrets and our own
  example hostnames/domain. **Supply your own secrets, change the defaults, and harden for your
  environment** before exposing anything. A misconfiguration in *your* deployment is not a
  vulnerability in this project, but reports of insecure **defaults** in the repo are welcome.
- **No secrets are committed.** Real credentials live in a local, gitignored `.env` generated
  from Infisical; only placeholders are in version control. If you believe you've found a real
  secret in the repo or its history, report it privately right away.
- **In scope:** insecure-by-default configuration, missing auth on a service that should be
  gated, container-hardening gaps, injection/SSRF/auth issues in any included code or scripts,
  and supply-chain concerns with pinned images.
- **Out of scope:** issues that require already-privileged LAN/host access by design (documented
  trust boundaries), and vulnerabilities in upstream third-party images/projects (report those
  to the respective upstream; we'll bump pins once fixed).

## Supported versions

This project tracks a single rolling `main`. Security fixes land on `main`; there are no
long-term support branches.
