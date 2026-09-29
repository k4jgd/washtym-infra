#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/common.sh"

APPLICATION=""
CONFIRM=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --application) APPLICATION="${2:-}"; shift 2 ;;
    --confirm) CONFIRM=true; shift ;;
    *) echo "Usage: $0 --application mlflow|airflow --confirm" >&2; exit 2 ;;
  esac
done
[[ "$CONFIRM" == true ]] || die "Database reset requires --confirm."
require_initialized
case "$APPLICATION" in
  mlflow) database="$(env_value MLFLOW_DB)"; owner="$(env_value MLFLOW_DB_USER)" ;;
  airflow) database="$(env_value AIRFLOW_DB)"; owner="$(env_value AIRFLOW_DB_USER)" ;;
  *) die "--application must be mlflow or airflow." ;;
esac
wait_for_postgres
admin_user="$(env_value POSTGRES_ADMIN_USER)"
admin_db="$(env_value POSTGRES_DEFAULT_DB)"

"${COMPOSE[@]}" exec -T postgres psql -v ON_ERROR_STOP=1 -U "$admin_user" -d "$admin_db" \
  -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='$database' AND pid <> pg_backend_pid()" \
  -c "DROP DATABASE IF EXISTS \"$database\"" \
  -c "CREATE DATABASE \"$database\" OWNER \"$owner\"" \
  -c "REVOKE CONNECT ON DATABASE \"$database\" FROM PUBLIC" \
  -c "GRANT CONNECT ON DATABASE \"$database\" TO \"$owner\""
"${COMPOSE[@]}" exec -T postgres psql -v ON_ERROR_STOP=1 -U "$admin_user" -d "$database" \
  -c "REVOKE ALL ON SCHEMA public FROM PUBLIC" \
  -c "GRANT ALL ON SCHEMA public TO \"$owner\""

echo "Reset only the $APPLICATION database: $database"
