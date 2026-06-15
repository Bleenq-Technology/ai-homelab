# MLflow tracking server with Postgres backend + S3 (MinIO) artifact store.
FROM python:3.12-slim
RUN pip install --no-cache-dir "mlflow==3.13.0" psycopg2-binary boto3
EXPOSE 5000
