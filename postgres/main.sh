#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
[[ "$(uname -s)" == "Linux" ]] || { echo "Run this on the Linux server." >&2; exit 1; }
[[ "$EUID" -ne 0 ]] || { echo "Run as the normal deployment user, not root." >&2; exit 1; }
command -v docker >/dev/null 2>&1 || { echo "Docker is required. Run an application main.sh first or install Docker." >&2; exit 1; }
docker info >/dev/null 2>&1 || { echo "Docker is unavailable to $(id -un)." >&2; exit 1; }
command -v openssl >/dev/null 2>&1 || { echo "openssl is required." >&2; exit 1; }

[[ -f "$PROJECT_DIR/.env" ]] || cp "$PROJECT_DIR/.env.example" "$PROJECT_DIR/.env"
install -d -m 0700 "$PROJECT_DIR/secrets" "$PROJECT_DIR/backups"

generate_secret() {
  local path="$PROJECT_DIR/secrets/$1"
  if [[ ! -s "$path" ]]; then
    umask 077
    openssl rand -hex "$2" > "$path"
  fi
  chmod 0644 "$path"
}

generate_secret postgres_admin_password 32
generate_secret mlflow_db_password 32
generate_secret airflow_db_password 32
chmod +x "$PROJECT_DIR/scripts/"*.sh "$PROJECT_DIR/docker/"*.sh

source "$PROJECT_DIR/scripts/common.sh"
info "Validating shared PostgreSQL configuration"
"${COMPOSE[@]}" config --quiet
info "Pulling PostgreSQL"
"${COMPOSE[@]}" pull postgres
info "Starting shared PostgreSQL"
"${COMPOSE[@]}" up -d postgres
wait_for_postgres
info "Creating or validating the isolated application databases"
"${COMPOSE[@]}" exec -T postgres bash /opt/localinfra/init-app-databases.sh

echo "Shared PostgreSQL is ready on the private Docker network localinfra_data."
echo "Databases: $(env_value MLFLOW_DB), $(env_value AIRFLOW_DB)"
