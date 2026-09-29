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

info "Backing up the Airflow metadata database"
"${POSTGRES_COMPOSE[@]}" exec -T postgres \
  pg_dump -U "$db_user" -d "$db_name" --format=custom \
  > "$destination/postgres.dump"

info "Backing up DAGs and task logs"
tar -C "$PROJECT_DIR" -czf "$destination/dags.tar.gz" dags
tar -C "$PROJECT_DIR" -czf "$destination/logs.tar.gz" logs

info "Backing up configuration and encryption secrets"
tar -C "$PROJECT_DIR" -czf "$destination/configuration.tar.gz" \
  .env compose.yaml Dockerfile requirements.txt config plugins docker scripts secrets runtime \
  main.sh reset-airflow.sh

sha256sum "$destination"/* > "$destination/SHA256SUMS"
chmod 0600 "$destination"/*

retention="$(env_value BACKUP_RETENTION_DAYS)"
if [[ "$retention" =~ ^[0-9]+$ ]] && ((retention > 0)); then
  find "$PROJECT_DIR/backups" -mindepth 1 -maxdepth 1 -type d \
    -mtime "+$retention" -print -exec rm -rf -- {} +
fi

echo "Backup created: $destination"
echo "It contains credentials and the Fernet key. Copy it to encrypted off-server storage."
