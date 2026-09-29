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
[[ "$CONFIRM" == true ]] || die "Restore replaces current database and artifacts. Pass --confirm-data-replacement."
[[ -f "$BACKUP_DIR/postgres.dump" ]] || die "postgres.dump not found in $BACKUP_DIR"
[[ -f "$BACKUP_DIR/artifacts.tar.gz" ]] || die "artifacts.tar.gz not found in $BACKUP_DIR"

require_command docker
require_initialized

if [[ -f "$BACKUP_DIR/SHA256SUMS" ]]; then
  info "Verifying backup checksums"
  (cd "$BACKUP_DIR" && sha256sum --check SHA256SUMS)
fi

echo "This operation will replace the live MLflow database and artifact storage."
read -r -p "Type RESTORE to continue: " answer
[[ "$answer" == "RESTORE" ]] || die "Restore cancelled."

info "Stopping writers"
"${COMPOSE[@]}" stop mlflow minio
artifact_volume="mlflow_minio_data"
require_shared_postgres

db_user="$(env_value POSTGRES_USER)"
db_name="$(env_value POSTGRES_DB)"

info "Restoring PostgreSQL"
"${POSTGRES_COMPOSE[@]}" exec -T postgres \
  pg_restore -U "$db_user" -d "$db_name" --clean --if-exists --no-owner \
  < "$BACKUP_DIR/postgres.dump"

info "Replacing the artifact volume"
docker run --rm \
  --mount type=volume,src="$artifact_volume",dst=/target \
  alpine:3.22 sh -c 'find /target -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +'
docker run --rm \
  --mount type=volume,src="$artifact_volume",dst=/target \
  --mount type=bind,src="$BACKUP_DIR",dst=/backup,readonly \
  alpine:3.22 tar -C /target -xzf /backup/artifacts.tar.gz

info "Starting services"
start_configured_stack
wait_for_mlflow_container
echo "Restore completed. Run scripts/status.sh."
