#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"

[[ "$EUID" -ne 0 ]] || { echo "Run this script as the normal deployment user." >&2; exit 1; }
command -v openssl >/dev/null 2>&1 || { echo "openssl is required." >&2; exit 1; }

if [[ ! -f "$PROJECT_DIR/.env" ]]; then
  cp "$PROJECT_DIR/.env.example" "$PROJECT_DIR/.env"
fi

sed -i \
  -e "s|^MLFLOW_UID=.*|MLFLOW_UID=$(id -u)|" \
  -e "s|^MLFLOW_GID=.*|MLFLOW_GID=$(id -g)|" \
  "$PROJECT_DIR/.env"

install -d -m 0700 "$PROJECT_DIR/secrets" "$PROJECT_DIR/runtime" "$PROJECT_DIR/backups"

generate_secret() {
  local name="$1"
  local bytes="$2"
  local path="$PROJECT_DIR/secrets/$name"
  if [[ ! -s "$path" ]]; then
    umask 077
    openssl rand -hex "$bytes" > "$path"
  fi
  chmod 0644 "$path"
}

generate_secret mlflow_flask_secret 48
generate_secret mlflow_admin_password 24
generate_secret minio_access_key 16
generate_secret minio_secret_key 32
chmod +x "$PROJECT_DIR/scripts/"*.sh "$PROJECT_DIR/docker/"*.sh 2>/dev/null || true

echo "Configuration and secrets are initialized."
