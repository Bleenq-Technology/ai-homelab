# Contributing to ai-homelab-infra

Thanks for your interest. This repository is the open reference architecture for a
production-style, self-hostable AI/LLM platform, maintained by **Bleenq LLC**. Contributions
that make it clearer, safer, or more broadly useful are welcome.

## What this project is (and isn't)

It's a **reference architecture** — modular Docker Compose stacks (`core` / `data` / `monitoring`
/ `ai`) plus host services, wired together with Traefik, Keycloak, Infisical, and a full
observability layer. It is meant to be **read, adapted, and self-hosted**, not consumed as a
turnkey SaaS. Our environment-specific values (the `*.pdx.sanctioned.tech` domain, the `jarvis`
host, internal IPs) appear throughout as concrete examples — keep contributions
**parameterized/placeholdered** rather than hard-coding a new environment's specifics.

## Ways to contribute

- **Issues** — bugs, unclear docs, broken setup steps, or proposals for new services/patterns.
- **Pull requests** — fixes, hardening, new service modules, documentation, or examples.
- **Discussion** — architecture questions and "how would you do X" are welcome in issues.

## Ground rules

1. **Never commit real secrets.** All credentials come from a local, gitignored `.env`
   (generated from Infisical) — see [`docker/.env.example`](docker/.env.example) for the template.
   Only ever commit placeholder values. CI runs secret scanning on every PR, and the repo has
   push protection enabled, but the first line of defense is you.
2. **Keep images pinned.** Pin to a specific, audited stable tag/digest — no mutable
   `:latest` / `:main`. Note the version and why in your PR if you bump one.
3. **Respect the network segmentation.** A service joins only the networks it needs
   (`proxy` / `data` / `ai` / `monitoring`). Anything user-facing goes behind Traefik with the
   appropriate auth middleware (Keycloak SSO / forward-auth); don't expose admin UIs unauthenticated.
4. **Keep it generalizable.** Prefer env vars / placeholders over hard-coded hostnames, IPs,
   emails, or paths. Don't add anyone's personal data.
5. **Document it.** New services get a short README and a Roadmap/Services entry. Update the
   architecture diagram if you change a dependency.
6. **Test before you commit.** Confirm the thing actually starts and works; one logical change
   per commit, with a clear message.

## Pull request process

1. Fork and create a feature branch (`feat/...`, `fix/...`, `docs/...`).
2. Make your change; run a local secret scan (`gitleaks detect`) before pushing.
3. Open a PR describing **what** changed and **why**, plus how you verified it.
4. CI (secret scan, IaC config scan, and an automated security review) must pass.
5. A maintainer reviews and merges. Be patient and kind — this is a small team.

## Security issues

Please do **not** open a public issue for a vulnerability. Follow [SECURITY.md](SECURITY.md).

## License of contributions

By contributing, you agree your contributions are licensed under the repository's
[MIT License](LICENSE).
