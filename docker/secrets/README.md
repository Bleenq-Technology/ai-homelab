# Docker secrets

Real secret values live **only on jarvis**, never in git. This folder is
gitignored except for this README and `.gitkeep`.

Traefik reads the EasyDNS API credentials here via lego's `_FILE` convention
(`EASYDNS_TOKEN_FILE` / `EASYDNS_KEY_FILE`), so they never appear in `docker ps`,
environment dumps, or the compose file.

## Create the secret files on jarvis

Use `printf` (no trailing newline — a trailing `\n` breaks the API auth):

```bash
cd docker/secrets
printf '%s' 'YOUR_EASYDNS_API_TOKEN' > easydns_token
printf '%s' 'YOUR_EASYDNS_API_KEY'   > easydns_key
chmod 600 easydns_token easydns_key
```

## Getting the EasyDNS credentials

1. Log into the EasyDNS control panel (cp.easydns.com).
2. Open the **REST API** section. If you don't see a token/key generator,
   open a support ticket asking EasyDNS to enable REST API access on the account.
3. Generate the **token + key** pair → those become `easydns_token` / `easydns_key`.

The DNS-01 challenge writes a TXT record via this API, so jarvis only needs
**outbound** access to `rest.easydns.net` — port 80 does **not** need to be
reachable from the internet for certificate issuance.
