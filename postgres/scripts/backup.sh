#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/common.sh"

require_initialized
wait_for_postgres
timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
destination="$PROJECT_DIR/backups/$timestamp"
mkdir -p "$destination"
chmod 0700 "$destination"

admin="$(env_value POSTGRES_ADMIN_USER)"
"${COMPOSE[@]}" exec -T postgres pg_dumpall -U "$admin" --globals-only \
  > "$destination/globals.sql"
for database in "$(env_value MLFLOW_DB)" "$(env_value AIRFLOW_DB)"; do
  "${COMPOSE[@]}" exec -T postgres pg_dump -U "$admin" -d "$database" --format=custom \
    > "$destination/${database}.dump"
done
tar -C "$PROJECT_DIR" -czf "$destination/configuration.tar.gz" \
  .env compose.yaml docker scripts secrets main.sh
sha256sum "$destination"/* > "$destination/SHA256SUMS"
chmod 0600 "$destination"/*

retention="$(env_value BACKUP_RETENTION_DAYS)"
if [[ "$retention" =~ ^[0-9]+$ ]] && ((retention > 0)); then
  find "$PROJECT_DIR/backups" -mindepth 1 -maxdepth 1 -type d -mtime "+$retention" -print -exec rm -rf -- {} +
fi
echo "Shared PostgreSQL backup created: $destination"
echo "Copy this credential-bearing backup to encrypted off-server storage."
