#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
DOMAIN=""
EMAIL=""

usage() {
  echo "Usage: $0 --domain mlflow.example.com --email admin@example.com"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --domain) DOMAIN="${2:-}"; shift 2 ;;
    --email) EMAIL="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

[[ -n "$DOMAIN" ]] || { usage; echo "--domain is required" >&2; exit 2; }
[[ "$EUID" -ne 0 ]] || { echo "Run this script as the non-root deployment user." >&2; exit 1; }
[[ "$DOMAIN" =~ ^[A-Za-z0-9.-]+$ ]] || { echo "Invalid domain name" >&2; exit 2; }
[[ "$EMAIL" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] || {
  usage
  echo "A valid --email is required" >&2
  exit 2
}
command -v openssl >/dev/null 2>&1 || { echo "openssl is required" >&2; exit 1; }

if [[ ! -f "$PROJECT_DIR/.env" ]]; then
  cp "$PROJECT_DIR/.env.example" "$PROJECT_DIR/.env"
fi

sed -i \
  -e "s|^DOMAIN=.*|DOMAIN=${DOMAIN}|" \
  -e "s|^ACME_EMAIL=.*|ACME_EMAIL=${EMAIL}|" \
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
  # The parent directory is owner-only. Read permission is needed by the
  # unprivileged container UIDs through Compose's file-backed secrets.
  chmod 0644 "$path"
}

generate_secret postgres_password 32
generate_secret mlflow_flask_secret 48
generate_secret mlflow_admin_password 24
generate_secret minio_access_key 16
generate_secret minio_secret_key 32
chmod +x "$PROJECT_DIR/scripts/"*.sh "$PROJECT_DIR/docker/"*.sh

echo "Configuration initialized."
echo "Configured host: ${DOMAIN}"
echo "Initial admin username: admin"
echo "Initial admin password is stored in: secrets/mlflow_admin_password"
echo "Run main.sh to deploy in local, VPN, or HTTPS mode."
