#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
LOCALINFRA_DIR="$(cd -- "$PROJECT_DIR/.." && pwd)"
MLFLOW_DIR="$LOCALINFRA_DIR/mlflow"
COMPOSE=(docker compose --project-directory "$PROJECT_DIR" --env-file "$PROJECT_DIR/.env" -f "$PROJECT_DIR/compose.yaml")
GATEWAY_COMPOSE=(docker compose --project-directory "$MLFLOW_DIR" --env-file "$MLFLOW_DIR/.env" -f "$MLFLOW_DIR/compose.yaml")

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
  [[ -d "$PROJECT_DIR/secrets" ]] || die "Secrets directory is missing."
  for secret in postgres_password airflow_fernet_key airflow_jwt_secret airflow_api_secret airflow_admin_password; do
    [[ -s "$PROJECT_DIR/secrets/$secret" ]] || die "Missing secret: secrets/$secret"
  done
  [[ -f "$MLFLOW_DIR/.env" ]] || die "Initialize and deploy MLflow first; its Caddy service is the shared HTTPS gateway."
}

env_value() {
  local key="$1"
  local value
  value="$(sed -n "s/^${key}=//p" "$PROJECT_DIR/.env" | tail -n 1)"
  [[ -n "$value" ]] || die "Missing $key in .env"
  printf '%s' "$value"
}

wait_for_service() {
  local service="$1"
  local attempts="${2:-50}"
  local delay="${3:-5}"
  local container_id status

  for ((i = 1; i <= attempts; i++)); do
    container_id="$("${COMPOSE[@]}" ps -q "$service" 2>/dev/null || true)"
    if [[ -n "$container_id" ]]; then
      status="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$container_id" 2>/dev/null || true)"
      if [[ "$status" == "healthy" || "$status" == "running" ]]; then
        return 0
      fi
    fi
    sleep "$delay"
  done

  "${COMPOSE[@]}" logs --tail=100 "$service" >&2 || true
  die "$service did not become healthy in time."
}

gateway_is_running() {
  [[ -n "$("${GATEWAY_COMPOSE[@]}" ps -q caddy 2>/dev/null || true)" ]]
}

reload_gateway() {
  gateway_is_running || die "The shared Caddy gateway is not running. Deploy MLflow first."
  "${GATEWAY_COMPOSE[@]}" exec -T caddy \
    caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
  "${GATEWAY_COMPOSE[@]}" exec -T caddy \
    caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile
}

