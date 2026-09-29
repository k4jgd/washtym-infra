#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/common.sh"

require_command docker
require_command curl
require_initialized

info "Running server preflight checks"
bash "$SCRIPT_DIR/preflight.sh"

domain="$(env_value DOMAIN)"

info "Pulling PostgreSQL and the Airflow base image"
"${COMPOSE[@]}" pull postgres

info "Building the pinned Airflow image"
"${COMPOSE[@]}" build --pull

info "Starting PostgreSQL"
"${COMPOSE[@]}" up -d postgres
for ((i = 1; i <= 30; i++)); do
  if "${COMPOSE[@]}" exec -T postgres pg_isready \
      -U "$(env_value POSTGRES_USER)" -d "$(env_value POSTGRES_DB)" >/dev/null 2>&1; then
    break
  fi
  ((i < 30)) || die "PostgreSQL did not become ready."
  sleep 2
done

if [[ ! -f "$PROJECT_DIR/runtime/initialized" ]]; then
  info "Migrating the database and creating the initial administrator"
  "${COMPOSE[@]}" run --rm airflow-init
  touch "$PROJECT_DIR/runtime/initialized"
  chmod 0600 "$PROJECT_DIR/runtime/initialized"
else
  info "Applying pending Airflow database migrations"
  "${COMPOSE[@]}" run --rm --no-deps airflow-api-server airflow db migrate
fi

info "Starting Airflow services"
"${COMPOSE[@]}" up -d --remove-orphans \
  airflow-api-server airflow-scheduler airflow-dag-processor airflow-triggerer

wait_for_service airflow-api-server
wait_for_service airflow-scheduler
wait_for_service airflow-dag-processor
wait_for_service airflow-triggerer

info "Reloading the shared HTTPS gateway"
reload_gateway

info "Checking the public endpoint"
if curl --fail --silent --show-error --max-time 20 \
    "https://${domain}/api/v2/monitor/health" >/dev/null; then
  echo "Airflow is healthy at https://${domain}"
else
  echo "Airflow is healthy inside Docker, but its public HTTPS check failed." >&2
  echo "Confirm DNS and inspect the shared gateway logs from ../mlflow." >&2
  exit 1
fi

echo "Admin username: admin"
echo "Initial password: $PROJECT_DIR/secrets/airflow_admin_password"

