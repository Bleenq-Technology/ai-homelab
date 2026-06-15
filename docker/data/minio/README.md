# MinIO

**Purpose:** S3-compatible object storage (e.g. Langfuse media/event blobs).
**URL:** Console https://minio.pdx.sanctioned.tech · S3 API https://s3.pdx.sanctioned.tech
**Auth:** local login (root user / password)
**Image:** minio/minio:RELEASE.2025-04-08T15-41-24Z
**Networks / data:** `proxy` + `data` networks; bind mount `./minio/data` -> `/data`

## Setup as deployed
- Started with `server /data --console-address ":9001"`.
- Two Traefik routes (both `websecure`, `secure-chain@file`):
  - **Console** `minio.${DOMAIN}` -> container port **9001** (service `minio-console`)
  - **S3 API** `s3.${DOMAIN}` -> container port **9000** (service `minio-api`)
- `MINIO_SERVER_URL=https://s3.${DOMAIN}` and `MINIO_BROWSER_REDIRECT_URL=https://minio.${DOMAIN}` so the published URLs match the Traefik hostnames.
- Healthcheck uses `mc ready local`.
- Log in to the console with `MINIO_ROOT_USER` / `MINIO_ROOT_PASSWORD`.

### minio-init (one-shot companion)
- Image `minio/mc:RELEASE.2025-04-03T17-07-56Z`, on the `data` network, `restart: "no"`.
- Waits for MinIO to be `service_healthy`, then sets an `mc` alias and runs `mc mb --ignore-existing local/${LANGFUSE_S3_BUCKET}` — this is how the **Langfuse bucket** gets created on startup. Idempotent; exits after creating the bucket.

## Fixes & gotchas
- None specific beyond ensuring `MINIO_SERVER_URL` / `MINIO_BROWSER_REDIRECT_URL` point at the public Traefik hostnames so S3 and console redirects resolve correctly behind the proxy.

## Secrets
- `.env` keys: `MINIO_ROOT_USER`, `MINIO_ROOT_PASSWORD`, `LANGFUSE_S3_BUCKET`, `DOMAIN`, `TZ`.
- Real values live only in `/opt/homelab/.env` on jarvis (gitignored). Nothing sensitive is committed.
