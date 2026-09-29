#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
MLFLOW_DIR="$(cd -- "$PROJECT_DIR/../mlflow" && pwd)"
DOMAIN=""

usage() {
  echo "Usage: $0 --domain airflow.example.com"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --domain) DOMAIN="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

[[ "$EUID" -ne 0 ]] || { echo "Run this script as the non-root deployment user." >&2; exit 1; }
[[ -n "$DOMAIN" ]] || { usage; echo "--domain is required" >&2; exit 2; }
[[ "$DOMAIN" =~ ^[A-Za-z0-9.-]+$ ]] || { echo "Invalid domain name" >&2; exit 2; }
[[ -f "$MLFLOW_DIR/caddy/Caddyfile" ]] || { echo "The sibling mlflow Caddy configuration is missing." >&2; exit 1; }
command -v openssl >/dev/null 2>&1 || { echo "openssl is required" >&2; exit 1; }

if [[ ! -f "$PROJECT_DIR/.env" ]]; then
  cp "$PROJECT_DIR/.env.example" "$PROJECT_DIR/.env"
fi

sed -i \
  -e "s|^DOMAIN=.*|DOMAIN=${DOMAIN}|" \
  -e "s|^AIRFLOW_UID=.*|AIRFLOW_UID=$(id -u)|" \
  -e "s|^AIRFLOW_GID=.*|AIRFLOW_GID=0|" \
  "$PROJECT_DIR/.env"

install -d -m 0700 "$PROJECT_DIR/secrets" "$PROJECT_DIR/runtime" "$PROJECT_DIR/backups"
install -d -m 0755 "$PROJECT_DIR/dags" "$PROJECT_DIR/logs" "$PROJECT_DIR/plugins" "$PROJECT_DIR/config"
install -d -m 0755 "$MLFLOW_DIR/caddy/sites"

generate_hex_secret() {
  local name="$1"
  local bytes="$2"
  local path="$PROJECT_DIR/secrets/$name"
  if [[ ! -s "$path" ]]; then
    umask 077
    openssl rand -hex "$bytes" > "$path"
  fi
  chmod 0644 "$path"
}

generate_hex_secret postgres_password 32
generate_hex_secret airflow_jwt_secret 48
generate_hex_secret airflow_api_secret 48
generate_hex_secret airflow_admin_password 24

fernet_path="$PROJECT_DIR/secrets/airflow_fernet_key"
if [[ ! -s "$fernet_path" ]]; then
  umask 077
  openssl rand -base64 32 | tr '+/' '-_' | tr -d '\r\n' > "$fernet_path"
fi
chmod 0644 "$fernet_path"

max_body="$(sed -n 's/^MAX_REQUEST_BODY_SIZE=//p' "$PROJECT_DIR/.env" | tail -n 1)"
[[ "$max_body" =~ ^[0-9]+(KB|MB|GB)$ ]] || { echo "Invalid MAX_REQUEST_BODY_SIZE in .env" >&2; exit 1; }

site_file="$MLFLOW_DIR/caddy/sites/airflow.caddy"
printf '%s\n' \
  "${DOMAIN} {" \
  $'\tencode zstd gzip' \
  $'\trequest_body {' \
  $'\t\tmax_size '"${max_body}" \
  $'\t}' \
  $'\treverse_proxy airflow-api-server:8080 {' \
  $'\t\thealth_uri /api/v2/monitor/health' \
  $'\t\thealth_interval 30s' \
  $'\t\thealth_timeout 5s' \
  $'\t}' \
  $'\theader {' \
  $'\t\t-Server' \
  $'\t\tStrict-Transport-Security "max-age=31536000; includeSubDomains"' \
  $'\t\tX-Content-Type-Options "nosniff"' \
  $'\t\tReferrer-Policy "no-referrer"' \
  $'\t}' \
  $'\tlog {' \
  $'\t\toutput stdout' \
  $'\t\tformat json' \
  $'\t}' \
  '}' > "$site_file"
chmod 0644 "$site_file"

chmod +x "$PROJECT_DIR/scripts/"*.sh "$PROJECT_DIR/docker/"*.sh

echo "Airflow configuration initialized."
echo "Domain: https://${DOMAIN}"
echo "Initial admin username: admin"
echo "Initial admin password is stored in: secrets/airflow_admin_password"
echo "Deploy MLflow first so the shared Caddy gateway is running, then run scripts/deploy.sh."
