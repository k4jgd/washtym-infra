#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/common.sh"

require_command docker
require_command curl
require_initialized

info "Running local-only server preflight checks"
bash "$SCRIPT_DIR/preflight-local.sh"

local_port="$(sed -n 's/^MLFLOW_LOCAL_PORT=//p' "$PROJECT_DIR/.env" | tail -n 1)"
local_port="${local_port:-5000}"

info "Validating Compose configuration"
"${COMPOSE[@]}" config --quiet

info "Pulling the PostgreSQL image"
"${COMPOSE[@]}" pull postgres

info "Building the pinned MLflow image"
"${COMPOSE[@]}" build --pull mlflow

info "Starting PostgreSQL"
"${COMPOSE[@]}" up -d postgres

prepare_artifact_store

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

info "Starting MLflow on the server loopback interface"
"${COMPOSE[@]}" up -d --remove-orphans postgres
# Always recreate this container so Docker applies the loopback-only published
# port even when an earlier attempt created the service from compose.yaml alone.
"${COMPOSE[@]}" up -d --force-recreate --no-deps mlflow
wait_for_mlflow_container

if [[ ! -f "$PROJECT_DIR/runtime/auth-bootstrap-complete" ]]; then
  info "Finalizing the one-time administrator bootstrap"
  touch "$PROJECT_DIR/runtime/auth-bootstrap-complete"
  chmod 0600 "$PROJECT_DIR/runtime/auth-bootstrap-complete"
  "${COMPOSE[@]}" restart mlflow
  wait_for_mlflow_container
fi

info "Checking the loopback endpoint"
curl --fail --silent --show-error --max-time 15 \
  "http://127.0.0.1:${local_port}/health" >/dev/null \
  || die "MLflow is not reachable on 127.0.0.1:${local_port}."

echo "MLflow is healthy on the server at http://127.0.0.1:${local_port}"
echo "It is not exposed publicly. Connect with an SSH tunnel:"
echo "  ssh -N -L ${local_port}:127.0.0.1:${local_port} USER@SERVER_IP"
echo "Then open http://localhost:${local_port} on your computer."
echo "Admin username: admin"
echo "Initial password: $PROJECT_DIR/secrets/mlflow_admin_password"
