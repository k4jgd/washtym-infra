#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/common.sh"

require_command docker
require_command curl
require_initialized
bash "$SCRIPT_DIR/preflight.sh"

lan_ip="$(env_value AIRFLOW_LAN_IP)"
lan_port="$(env_value AIRFLOW_LAN_PORT)"

info "Building the pinned Airflow image"
"${COMPOSE[@]}" build --pull
require_shared_postgres

if [[ ! -f "$PROJECT_DIR/runtime/initialized" ]]; then
  info "Migrating the Airflow database and creating the administrator"
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

curl --fail --silent --show-error --max-time 20 \
  "http://${lan_ip}:${lan_port}/api/v2/monitor/health" >/dev/null \
  || die "Airflow is not reachable at http://${lan_ip}:${lan_port}."

echo "Airflow is healthy at http://${lan_ip}:${lan_port}"
echo "Admin username: admin"
echo "Initial password: $PROJECT_DIR/secrets/airflow_admin_password"
