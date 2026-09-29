#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"

[[ "$EUID" -ne 0 ]] || { echo "Run as the normal deployment user." >&2; exit 1; }
command -v openssl >/dev/null 2>&1 || { echo "openssl is required." >&2; exit 1; }
[[ -f "$PROJECT_DIR/.env" ]] || cp "$PROJECT_DIR/.env.example" "$PROJECT_DIR/.env"

sed -i \
  -e "s|^AIRFLOW_UID=.*|AIRFLOW_UID=$(id -u)|" \
  -e "s|^AIRFLOW_GID=.*|AIRFLOW_GID=0|" \
  "$PROJECT_DIR/.env"

install -d -m 0700 "$PROJECT_DIR/secrets" "$PROJECT_DIR/runtime" "$PROJECT_DIR/backups"
install -d -m 0755 "$PROJECT_DIR/dags" "$PROJECT_DIR/logs" "$PROJECT_DIR/plugins" "$PROJECT_DIR/config"

generate_hex_secret() {
  local path="$PROJECT_DIR/secrets/$1"
  if [[ ! -s "$path" ]]; then
    umask 077
    openssl rand -hex "$2" > "$path"
  fi
  chmod 0644 "$path"
}

generate_hex_secret airflow_jwt_secret 48
generate_hex_secret airflow_api_secret 48
generate_hex_secret airflow_admin_password 24

fernet_path="$PROJECT_DIR/secrets/airflow_fernet_key"
if [[ ! -s "$fernet_path" ]]; then
  umask 077
  openssl rand -base64 32 | tr '+/' '-_' | tr -d '\r\n' > "$fernet_path"
fi
chmod 0644 "$fernet_path"
chmod +x "$PROJECT_DIR/scripts/"*.sh "$PROJECT_DIR/docker/"*.sh

echo "Airflow configuration and secrets are initialized."
