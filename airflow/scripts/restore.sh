#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/common.sh"

BACKUP_DIR=""
CONFIRM=false

usage() {
  echo "Usage: $0 --backup /absolute/path/to/backup --confirm-data-replacement"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --backup) BACKUP_DIR="${2:-}"; shift 2 ;;
    --confirm-data-replacement) CONFIRM=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

[[ -n "$BACKUP_DIR" ]] || { usage; exit 2; }
BACKUP_DIR="$(cd -- "$BACKUP_DIR" && pwd)"
[[ "$CONFIRM" == true ]] || die "Restore replaces current metadata and logs. Pass --confirm-data-replacement."
[[ -f "$BACKUP_DIR/postgres.dump" ]] || die "postgres.dump not found in $BACKUP_DIR"
[[ -f "$BACKUP_DIR/logs.tar.gz" ]] || die "logs.tar.gz not found in $BACKUP_DIR"

require_command docker
require_initialized

if [[ -f "$BACKUP_DIR/SHA256SUMS" ]]; then
  info "Verifying backup checksums"
  (cd "$BACKUP_DIR" && sha256sum --check SHA256SUMS)
fi

echo "This replaces the live Airflow metadata database and task logs."
read -r -p "Type RESTORE-AIRFLOW to continue: " answer
[[ "$answer" == "RESTORE-AIRFLOW" ]] || die "Restore cancelled."

info "Stopping Airflow writers"
"${COMPOSE[@]}" stop airflow-api-server airflow-scheduler airflow-dag-processor airflow-triggerer
"${COMPOSE[@]}" up -d postgres

db_user="$(env_value POSTGRES_USER)"
db_name="$(env_value POSTGRES_DB)"

info "Restoring PostgreSQL"
"${COMPOSE[@]}" exec -T postgres \
  pg_restore -U "$db_user" -d "$db_name" --clean --if-exists --no-owner \
  < "$BACKUP_DIR/postgres.dump"

info "Replacing task logs"
find "$PROJECT_DIR/logs" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
tar -C "$PROJECT_DIR" -xzf "$BACKUP_DIR/logs.tar.gz"

info "Starting services"
"${COMPOSE[@]}" up -d airflow-api-server airflow-scheduler airflow-dag-processor airflow-triggerer
wait_for_service airflow-api-server
echo "Restore completed. Run scripts/status.sh and scripts/check-dags.sh."

