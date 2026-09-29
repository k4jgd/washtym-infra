#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
POSTGRES_DIR="$(cd -- "$PROJECT_DIR/../postgres" && pwd)"
COMPOSE=(docker compose --project-directory "$PROJECT_DIR" --env-file "$PROJECT_DIR/.env" -f "$PROJECT_DIR/compose.yaml")
POSTGRES_COMPOSE=(docker compose --project-directory "$POSTGRES_DIR" --env-file "$POSTGRES_DIR/.env" -f "$POSTGRES_DIR/compose.yaml")

die() { echo "ERROR: $*" >&2; exit 1; }
info() { echo "==> $*"; }
require_command() { command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"; }

require_initialized() {
  [[ -f "$PROJECT_DIR/.env" ]] || die "Run airflow/main.sh first."
  for secret in airflow_fernet_key airflow_jwt_secret airflow_api_secret airflow_admin_password; do
    [[ -s "$PROJECT_DIR/secrets/$secret" ]] || die "Missing airflow/secrets/$secret"
  done
  [[ -f "$POSTGRES_DIR/.env" ]] || die "Shared PostgreSQL is not initialized."
  [[ -s "$POSTGRES_DIR/secrets/airflow_db_password" ]] || die "Shared Airflow database password is missing."
}

env_value() {
  local value
  value="$(sed -n "s/^$1=//p" "$PROJECT_DIR/.env" | tail -n 1)"
  [[ -n "$value" ]] || die "Missing $1 in airflow/.env"
  printf '%s' "$value"
}

postgres_env_value() {
  local value
  value="$(sed -n "s/^$1=//p" "$POSTGRES_DIR/.env" | tail -n 1)"
  [[ -n "$value" ]] || die "Missing $1 in postgres/.env"
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
  local service="$1" attempts="${2:-50}" delay="${3:-5}" container_id status
  for ((i = 1; i <= attempts; i++)); do
    container_id="$("${COMPOSE[@]}" ps -q "$service" 2>/dev/null || true)"
    if [[ -n "$container_id" ]]; then
      status="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$container_id" 2>/dev/null || true)"
      [[ "$status" == "healthy" || "$status" == "running" ]] && return 0
    fi
    sleep "$delay"
  done
  "${COMPOSE[@]}" logs --tail=100 "$service" >&2 || true
  die "$service did not become healthy in time."
}
