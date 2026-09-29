#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/common.sh"

COMPOSE+=( -f "$PROJECT_DIR/compose.lan.yaml" )

require_command docker
require_command curl
require_initialized

info "Running LAN server preflight checks"
bash "$SCRIPT_DIR/preflight-lan.sh"

lan_ip="$(env_value MLFLOW_LAN_IP)"
lan_port="$(sed -n 's/^MLFLOW_LAN_PORT=//p' "$PROJECT_DIR/.env" | tail -n 1)"
lan_port="${lan_port:-5000}"

info "Validating Compose configuration"
"${COMPOSE[@]}" config --quiet

info "Pulling the PostgreSQL image"
"${COMPOSE[@]}" pull postgres

info "Building the pinned MLflow image"
"${COMPOSE[@]}" build --pull mlflow

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

info "Applying MLflow tracking database migrations"
# The URI is intentionally expanded by the shell inside the container.
# shellcheck disable=SC2016
"${COMPOSE[@]}" run --rm --no-deps mlflow \
  bash -lc 'mlflow db upgrade "$MLFLOW_BACKEND_STORE_URI"'

info "Starting MLflow on the office LAN interface"
"${COMPOSE[@]}" up -d --remove-orphans postgres
"${COMPOSE[@]}" up -d --force-recreate --no-deps mlflow
wait_for_mlflow_container

if [[ ! -f "$PROJECT_DIR/runtime/auth-bootstrap-complete" ]]; then
  info "Finalizing the one-time administrator bootstrap"
  touch "$PROJECT_DIR/runtime/auth-bootstrap-complete"
  chmod 0600 "$PROJECT_DIR/runtime/auth-bootstrap-complete"
  "${COMPOSE[@]}" restart mlflow
  wait_for_mlflow_container
fi

info "Checking the LAN endpoint"
curl --fail --silent --show-error --max-time 15 \
  "http://${lan_ip}:${lan_port}/health" >/dev/null \
  || die "MLflow is not reachable on ${lan_ip}:${lan_port}."

echo "MLflow is healthy at http://${lan_ip}:${lan_port}"
echo "The port is bound only to the server LAN address."
echo "Admin username: admin"
echo "Initial password: $PROJECT_DIR/secrets/mlflow_admin_password"

