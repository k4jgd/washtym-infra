#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
POSTGRES_DIR="$(cd -- "$PROJECT_DIR/../postgres" && pwd)"
COMPOSE=(
  docker compose
  --project-directory "$PROJECT_DIR"
  --env-file "$PROJECT_DIR/.env"
  -f "$PROJECT_DIR/compose.yaml"
  -f "$PROJECT_DIR/compose.minio.yaml"
  -f "$PROJECT_DIR/compose.lan.yaml"
)
POSTGRES_COMPOSE=(docker compose --project-directory "$POSTGRES_DIR" --env-file "$POSTGRES_DIR/.env" -f "$POSTGRES_DIR/compose.yaml")

die() {
  echo "ERROR: $*" >&2
  exit 1
}

info() {
  echo "==> $*"
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

require_initialized() {
  [[ -f "$PROJECT_DIR/.env" ]] || die "Run main.sh first."
  [[ -d "$PROJECT_DIR/secrets" ]] || die "Secrets directory is missing. Run main.sh."
  for secret in \
    mlflow_flask_secret \
    mlflow_admin_password \
    minio_access_key \
    minio_secret_key; do
    [[ -s "$PROJECT_DIR/secrets/$secret" ]] || die "Missing secret: secrets/$secret"
  done
  [[ -f "$POSTGRES_DIR/.env" ]] || die "Shared PostgreSQL is not initialized."
  [[ -s "$POSTGRES_DIR/secrets/mlflow_db_password" ]] || die "Shared MLflow database password is missing."
}

env_value() {
  local key="$1"
  local value
  value="$(sed -n "s/^${key}=//p" "$PROJECT_DIR/.env" | tail -n 1)"
  [[ -n "$value" ]] || die "Missing $key in .env"
  printf '%s' "$value"
}

postgres_env_value() {
  local key="$1" value
  value="$(sed -n "s/^${key}=//p" "$POSTGRES_DIR/.env" | tail -n 1)"
  [[ -n "$value" ]] || die "Missing $key in postgres/.env"
  printf '%s' "$value"
}

require_shared_postgres() {
  local container_id status
  container_id="$("${POSTGRES_COMPOSE[@]}" ps -q postgres 2>/dev/null || true)"
  [[ -n "$container_id" ]] || die "Shared PostgreSQL is not running. Run postgres/main.sh."
  status="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$container_id" 2>/dev/null || true)"
  [[ "$status" == "healthy" ]] || die "Shared PostgreSQL is not healthy."
}

wait_for_service() {
  local service="$1"
  local attempts="${2:-40}"
  local delay="${3:-5}"
  local container_id status

  for ((i = 1; i <= attempts; i++)); do
    container_id="$("${COMPOSE[@]}" ps -q "$service" 2>/dev/null || true)"
    if [[ -n "$container_id" ]]; then
      status="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$container_id" 2>/dev/null || true)"
      [[ "$status" == "healthy" ]] && return 0
    fi
    sleep "$delay"
  done

  "${COMPOSE[@]}" logs --tail=100 "$service" >&2 || true
  die "$service did not become healthy in time."
}

wait_for_mlflow_container() {
  wait_for_service mlflow "${1:-40}" "${2:-5}"
}

prepare_artifact_store() {
  info "Building pinned MinIO from the official source tag"
  "${COMPOSE[@]}" build minio

  info "Starting MinIO"
  "${COMPOSE[@]}" up -d minio
  wait_for_service minio 60 5

  info "Creating or validating the private MinIO artifact bucket"
  "${COMPOSE[@]}" run --rm --no-deps minio-init
}

start_configured_stack() {
  require_shared_postgres
  prepare_artifact_store
  "${COMPOSE[@]}" up -d --remove-orphans mlflow
}
