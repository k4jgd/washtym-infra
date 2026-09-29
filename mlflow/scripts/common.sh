#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
COMPOSE=(docker compose --project-directory "$PROJECT_DIR" --env-file "$PROJECT_DIR/.env" -f "$PROJECT_DIR/compose.yaml")

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
  [[ -f "$PROJECT_DIR/.env" ]] || die "Run scripts/init-config.sh first."
  [[ -d "$PROJECT_DIR/secrets" ]] || die "Secrets directory is missing. Run scripts/init-config.sh."
  for secret in postgres_password mlflow_flask_secret mlflow_admin_password; do
    [[ -s "$PROJECT_DIR/secrets/$secret" ]] || die "Missing secret: secrets/$secret"
  done
}

env_value() {
  local key="$1"
  local value
  value="$(sed -n "s/^${key}=//p" "$PROJECT_DIR/.env" | tail -n 1)"
  [[ -n "$value" ]] || die "Missing $key in .env"
  printf '%s' "$value"
}

wait_for_mlflow_container() {
  local attempts="${1:-40}"
  local delay="${2:-5}"
  local container_id status

  for ((i = 1; i <= attempts; i++)); do
    container_id="$("${COMPOSE[@]}" ps -q mlflow 2>/dev/null || true)"
    if [[ -n "$container_id" ]]; then
      status="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$container_id" 2>/dev/null || true)"
      if [[ "$status" == "healthy" ]]; then
        return 0
      fi
    fi
    sleep "$delay"
  done

  "${COMPOSE[@]}" logs --tail=100 mlflow >&2 || true
  die "MLflow did not become healthy in time."
}
