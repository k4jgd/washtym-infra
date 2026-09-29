#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/common.sh"

PURGE=false
if [[ "${1:-}" == "--purge-data" ]]; then
  PURGE=true
elif [[ $# -gt 0 ]]; then
  echo "Usage: $0 [--purge-data]" >&2
  exit 2
fi

require_command docker
require_initialized

"${COMPOSE[@]}" down --remove-orphans
rm -f -- "$MLFLOW_DIR/caddy/sites/airflow.caddy"
if gateway_is_running; then
  reload_gateway
fi

if [[ "$PURGE" == false ]]; then
  echo "Airflow containers and routing were removed. Database, DAGs, logs, secrets, and backups were preserved."
  echo "Run scripts/init-config.sh again before redeploying to restore the gateway route."
  exit 0
fi

echo "WARNING: This permanently deletes the Airflow PostgreSQL volume and task logs."
echo "DAGs, configuration, secrets, and backup files are preserved."
read -r -p "Type PURGE-AIRFLOW-DATA to continue: " answer
[[ "$answer" == "PURGE-AIRFLOW-DATA" ]] || die "Purge cancelled."

docker volume rm airflow_postgres_data >/dev/null 2>&1 || true
find "$PROJECT_DIR/logs" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
rm -f -- "$PROJECT_DIR/runtime/initialized"
echo "Airflow database volume and task logs were deleted."
