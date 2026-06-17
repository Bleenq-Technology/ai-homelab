# MLflow
**Purpose:** ML experiment tracking + model registry + artifact store (for training/backtest runs).
**URL:** https://mlflow.pdx.sanctioned.tech (UI) — ML jobs use the internal `http://mlflow:5000`
**Auth:** Keycloak forward-auth (`secure-sso@file`) on the UI; the in-cluster endpoint is unauthenticated (reachable only on the Docker networks).
**Image:** built from [`Dockerfile`](Dockerfile) → `homelab/mlflow:3.13.0` (python:3.12-slim + `mlflow==3.13.0` + `psycopg2-binary` + `boto3`)
**GPU:** no (the tracking server is light; training jobs use the GPU separately and log here)
**Networks / data:** `proxy` + `ai` + `data`; state in Postgres + MinIO (no bind mount)

## Setup as deployed
- **Backend store:** Postgres DB `mlflow` (role `mlflow`, password `MLFLOW_DB_PASSWORD`).
- **Artifact store:** MinIO bucket `mlflow`, via `--artifacts-destination s3://mlflow/ --serve-artifacts`
  — the server **proxies artifacts**, so clients do NOT need S3 credentials. The server reaches MinIO
  with `MLFLOW_S3_ENDPOINT_URL=http://minio:9000` + `AWS_ACCESS_KEY_ID/SECRET` (MinIO root creds).
- **Command:** `mlflow server --host 0.0.0.0 --port 5000 --backend-store-uri postgresql://… --artifacts-destination s3://mlflow/ --serve-artifacts`.
- **UI** routed at `mlflow.${DOMAIN}`, gated by `secure-sso@file` (oauth2-proxy / Keycloak) — no
  per-host redirect URI needed; the shared `auth.${DOMAIN}/oauth2/callback` covers it.
- **Host-header guard:** MLflow 3.x rejects unknown `Host` headers with `403` (DNS-rebinding
  protection); `MLFLOW_SERVER_ALLOWED_HOSTS=*` is set so both the public host and internal
  `http://mlflow:5000` callers work — safe here behind Traefik host-routing + SSO + private nets.
- **DNS:** add `mlflow.pdx.sanctioned.tech → 192.168.2.10` on the EdgeRouter (static-host-mapping).

## Usage
- **ML jobs / containers** (on the `ai` network) log over the internal endpoint — no auth:
  ```python
  import mlflow
  mlflow.set_tracking_uri("http://mlflow:5000")
  mlflow.set_experiment("orb-backtest")
  with mlflow.start_run():
      mlflow.log_params({"lookback": 20})
      mlflow.log_metric("sharpe", 1.4)
      mlflow.log_artifact("equity_curve.png")   # uploaded via the server -> MinIO
  ```
- **Humans:** browse https://mlflow.pdx.sanctioned.tech (Keycloak login).

## Secrets
- `.env` keys: `MLFLOW_DB_PASSWORD`, plus `MINIO_ROOT_USER`/`MINIO_ROOT_PASSWORD` for the artifact store.
  All in Infisical; nothing committed to git.

## Issues & Fixes
**Symptom:** none — clean deploy. (The `mlflow` Postgres role/DB and `mlflow` MinIO bucket are created
out-of-band, not by an init script, since MLflow's own migrations build the schema on first start.)
