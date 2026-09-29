#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/common.sh"

NEW_VERSION="${1:-}"
[[ "$NEW_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  echo "Usage: $0 NEW_AIRFLOW_VERSION (example: $0 3.3.3)" >&2
  exit 2
}

require_command docker
require_initialized

old_version="$(env_value AIRFLOW_VERSION)"
[[ "$NEW_VERSION" != "$old_version" ]] || die "Airflow is already configured for $NEW_VERSION."

info "Creating a pre-upgrade backup"
bash "$SCRIPT_DIR/backup.sh"

info "Stopping Airflow while preserving PostgreSQL"
"${COMPOSE[@]}" stop airflow-api-server airflow-scheduler airflow-dag-processor airflow-triggerer
sed -i "s/^AIRFLOW_VERSION=.*/AIRFLOW_VERSION=${NEW_VERSION}/" "$PROJECT_DIR/.env"

info "Building Airflow $NEW_VERSION"
if ! "${COMPOSE[@]}" build --pull; then
  sed -i "s/^AIRFLOW_VERSION=.*/AIRFLOW_VERSION=${old_version}/" "$PROJECT_DIR/.env"
  die "Image build failed; restored .env to Airflow $old_version."
fi

info "Applying database migrations"
"${COMPOSE[@]}" run --rm --no-deps airflow-api-server airflow db migrate

info "Starting upgraded services"
"${COMPOSE[@]}" up -d --remove-orphans \
  airflow-api-server airflow-scheduler airflow-dag-processor airflow-triggerer
wait_for_service airflow-api-server
wait_for_service airflow-scheduler

echo "Upgrade from $old_version to $NEW_VERSION completed."
echo "Keep the pre-upgrade backup until DAGs and task execution are verified."

