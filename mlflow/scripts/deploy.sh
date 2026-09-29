#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/common.sh"

require_command docker
require_command curl
require_initialized

info "Running server preflight checks"
bash "$SCRIPT_DIR/preflight.sh"

lan_ip="$(env_value MLFLOW_LAN_IP)"
lan_port="$(env_value MLFLOW_LAN_PORT)"

info "Building MLflow"
"${COMPOSE[@]}" build --pull mlflow

info "Checking shared PostgreSQL"
require_shared_postgres

prepare_artifact_store

info "Applying MLflow database migrations"
# shellcheck disable=SC2016
"${COMPOSE[@]}" run --rm --no-deps mlflow \
  bash -lc 'mlflow db upgrade "$MLFLOW_BACKEND_STORE_URI"'

info "Starting MLflow"
"${COMPOSE[@]}" up -d --force-recreate --no-deps mlflow
wait_for_mlflow_container

if [[ ! -f "$PROJECT_DIR/runtime/auth-bootstrap-complete" ]]; then
  info "Finalizing the one-time administrator bootstrap"
  touch "$PROJECT_DIR/runtime/auth-bootstrap-complete"
  chmod 0600 "$PROJECT_DIR/runtime/auth-bootstrap-complete"
  "${COMPOSE[@]}" restart mlflow
  wait_for_mlflow_container
fi

curl --fail --silent --show-error --max-time 15 \
  "http://${lan_ip}:${lan_port}/health" >/dev/null \
  || die "MLflow is not reachable on ${lan_ip}:${lan_port}."

echo "MLflow is healthy at http://${lan_ip}:${lan_port}"
