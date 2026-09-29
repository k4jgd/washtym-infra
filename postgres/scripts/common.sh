#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
COMPOSE=(docker compose --project-directory "$PROJECT_DIR" --env-file "$PROJECT_DIR/.env" -f "$PROJECT_DIR/compose.yaml")

die() { echo "ERROR: $*" >&2; exit 1; }
info() { echo "==> $*"; }

env_value() {
  local value
  value="$(sed -n "s/^$1=//p" "$PROJECT_DIR/.env" | tail -n 1)"
  [[ -n "$value" ]] || die "Missing $1 in .env"
  printf '%s' "$value"
}

require_initialized() {
  [[ -f "$PROJECT_DIR/.env" ]] || die "Run postgres/main.sh first."
  for secret in postgres_admin_password mlflow_db_password airflow_db_password; do
    [[ -s "$PROJECT_DIR/secrets/$secret" ]] || die "Missing postgres/secrets/$secret"
  done
}

wait_for_postgres() {
  local container_id status
  for ((i = 1; i <= 40; i++)); do
    container_id="$("${COMPOSE[@]}" ps -q postgres 2>/dev/null || true)"
    if [[ -n "$container_id" ]]; then
      status="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$container_id" 2>/dev/null || true)"
      [[ "$status" == "healthy" ]] && return 0
    fi
    sleep 3
  done
  "${COMPOSE[@]}" logs --tail=100 postgres >&2 || true
  die "Shared PostgreSQL did not become healthy."
}
