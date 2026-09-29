#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/common.sh"
require_initialized
wait_for_postgres
"${COMPOSE[@]}" ps
"${COMPOSE[@]}" exec -T postgres psql \
  -U "$(env_value POSTGRES_ADMIN_USER)" \
  -d "$(env_value POSTGRES_DEFAULT_DB)" \
  -Atc "SELECT datname FROM pg_database WHERE datname IN ('$(env_value MLFLOW_DB)','$(env_value AIRFLOW_DB)') ORDER BY datname"
