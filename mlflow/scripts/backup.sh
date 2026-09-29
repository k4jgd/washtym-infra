#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/common.sh"

require_command docker
require_command tar
require_initialized

timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
destination="$PROJECT_DIR/backups/$timestamp"
mkdir -p "$destination"
chmod 0700 "$destination"

db_user="$(env_value POSTGRES_USER)"
db_name="$(env_value POSTGRES_DB)"
artifact_store="$(configured_value ARTIFACT_STORE)"
artifact_store="${artifact_store:-local}"

info "Stopping MLflow writes for a consistent database and artifact backup"
"${COMPOSE[@]}" stop mlflow
restart_services() {
  if [[ "$artifact_store" == "minio" ]]; then
    "${COMPOSE[@]}" start minio >/dev/null 2>&1 || true
  fi
  "${COMPOSE[@]}" start mlflow >/dev/null 2>&1 || true
}
trap restart_services EXIT

info "Backing up PostgreSQL"
"${COMPOSE[@]}" exec -T postgres \
  pg_dump -U "$db_user" -d "$db_name" --format=custom \
  > "$destination/postgres.dump"

if [[ "$artifact_store" == "minio" ]]; then
  info "Stopping MinIO for a consistent data-volume snapshot"
  "${COMPOSE[@]}" stop minio

  info "Backing up the MinIO data volume"
  docker run --rm \
    --mount type=volume,src=mlflow_minio_data,dst=/source,readonly \
    --mount type=bind,src="$destination",dst=/backup \
    alpine:3.22 tar -C /source -czf /backup/artifacts.tar.gz .

  prepare_artifact_store
else
  info "Backing up the local MLflow artifact volume"
  docker run --rm \
    --mount type=volume,src=mlflow_artifacts,dst=/source,readonly \
    --mount type=bind,src="$destination",dst=/backup \
    alpine:3.22 tar -C /source -czf /backup/artifacts.tar.gz .
fi

"${COMPOSE[@]}" start mlflow
trap - EXIT

info "Backing up deployment configuration and secrets"
tar -C "$PROJECT_DIR" -czf "$destination/configuration.tar.gz" \
  .env compose.yaml compose.*.yaml Dockerfile caddy docker scripts secrets runtime \
  main.sh setup-*.sh reset-mlflow.sh

sha256sum "$destination"/* > "$destination/SHA256SUMS"
chmod 0600 "$destination"/*

retention="$(env_value BACKUP_RETENTION_DAYS)"
if [[ "$retention" =~ ^[0-9]+$ ]] && ((retention > 0)); then
  find "$PROJECT_DIR/backups" -mindepth 1 -maxdepth 1 -type d \
    -mtime "+$retention" -print -exec rm -rf -- {} +
fi

echo "Backup created: $destination"
echo "This backup contains secrets. Copy it to encrypted off-server storage."
