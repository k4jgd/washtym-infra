#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/common.sh"

require_command docker
require_command curl
require_initialized

info "Running server preflight checks"
bash "$SCRIPT_DIR/preflight.sh"

domain="$(env_value DOMAIN)"
email="$(env_value ACME_EMAIL)"
[[ "$domain" != "mlflow.example.com" ]] || die "Replace the example DOMAIN by running scripts/init-config.sh."
[[ "$email" != "admin@example.com" ]] || die "Replace the example ACME_EMAIL by running scripts/init-config.sh."

info "Validating Compose configuration"
"${COMPOSE[@]}" config --quiet

info "Ensuring the shared HTTPS edge network exists"
docker network inspect localinfra_edge >/dev/null 2>&1 \
  || docker network create localinfra_edge >/dev/null

info "Pulling base service images"
"${COMPOSE[@]}" pull postgres caddy

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

info "Starting MLflow and the HTTPS proxy"
"${COMPOSE[@]}" up -d --remove-orphans
wait_for_mlflow_container

if [[ ! -f "$PROJECT_DIR/runtime/auth-bootstrap-complete" ]]; then
  info "Finalizing the one-time administrator bootstrap"
  touch "$PROJECT_DIR/runtime/auth-bootstrap-complete"
  chmod 0600 "$PROJECT_DIR/runtime/auth-bootstrap-complete"
  "${COMPOSE[@]}" restart mlflow
  wait_for_mlflow_container
fi

info "Checking the public endpoint"
if curl --fail --silent --show-error --max-time 15 "https://${domain}/health" >/dev/null; then
  echo "MLflow is healthy at https://${domain}"
else
  echo "MLflow is healthy inside Docker, but the public HTTPS check failed." >&2
  echo "Confirm DNS, ports 80/443, and Caddy logs:" >&2
  echo "  docker compose logs caddy" >&2
  exit 1
fi

echo "Admin username: admin"
echo "Initial password: $PROJECT_DIR/secrets/mlflow_admin_password"
