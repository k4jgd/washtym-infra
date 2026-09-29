#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/common.sh"

NEW_VERSION="${1:-}"
[[ "$NEW_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  echo "Usage: $0 NEW_MLFLOW_VERSION (example: $0 3.16.1)" >&2
  exit 2
}

require_command docker
require_initialized

old_version="$(env_value MLFLOW_VERSION)"
[[ "$NEW_VERSION" != "$old_version" ]] || die "MLflow is already configured for $NEW_VERSION."

info "Creating a pre-upgrade backup"
bash "$SCRIPT_DIR/backup.sh"

info "Stopping MLflow writes while preserving PostgreSQL"
"${COMPOSE[@]}" stop caddy mlflow

sed -i "s/^MLFLOW_VERSION=.*/MLFLOW_VERSION=${NEW_VERSION}/" "$PROJECT_DIR/.env"

info "Building MLflow $NEW_VERSION"
if ! "${COMPOSE[@]}" build --pull mlflow; then
  sed -i "s/^MLFLOW_VERSION=.*/MLFLOW_VERSION=${old_version}/" "$PROJECT_DIR/.env"
  die "Image build failed; restored .env to MLflow $old_version."
fi

info "Applying database migrations"
# The URI is intentionally expanded by the shell inside the container.
# shellcheck disable=SC2016
"${COMPOSE[@]}" run --rm --no-deps mlflow \
  bash -lc 'mlflow db upgrade "$MLFLOW_BACKEND_STORE_URI"'

info "Starting upgraded services"
"${COMPOSE[@]}" up -d --remove-orphans
wait_for_mlflow_container
echo "Upgrade from $old_version to $NEW_VERSION completed."
echo "Database migrations are not automatically reversible; retain the pre-upgrade backup."
