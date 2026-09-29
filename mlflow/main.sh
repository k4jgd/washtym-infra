#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LAN_IP=""
LAN_PORT=""
SSH_PORT=22
CONFIGURE_FIREWALL=false
LAN_CIDR=""
SKIP_BOOTSTRAP=false

usage() {
  cat <<'EOF'
Usage:
  bash main.sh --lan-ip ADDRESS [options]

Example:
  bash main.sh --lan-ip 192.168.0.48 --port 5000

Options:
  --lan-ip ADDRESS         Static office-LAN IPv4 address of this server
  --port PORT              MLflow HTTP port (default: 5000)
  --configure-firewall     Configure UFW for SSH and the supplied LAN CIDR
  --lan-cidr CIDR          Office subnet allowed by UFW, e.g. 192.168.0.0/24
  --ssh-port PORT          SSH port allowed by UFW (default: 22)
  --skip-bootstrap         Fail instead of installing Docker when it is missing
  --email EMAIL            Accepted for compatibility; unused in HTTP LAN mode
  --mode lan               Accepted for compatibility
  -h, --help               Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --lan-ip) LAN_IP="${2:-}"; shift 2 ;;
    --port) LAN_PORT="${2:-}"; shift 2 ;;
    --configure-firewall) CONFIGURE_FIREWALL=true; shift ;;
    --lan-cidr) LAN_CIDR="${2:-}"; shift 2 ;;
    --ssh-port) SSH_PORT="${2:-}"; shift 2 ;;
    --skip-bootstrap) SKIP_BOOTSTRAP=true; shift ;;
    --email) shift 2 ;;
    --mode)
      [[ "${2:-}" == "lan" ]] || { echo "Only LAN mode is supported." >&2; exit 2; }
      shift 2
      ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

[[ "$(uname -s)" == "Linux" ]] || { echo "Run this on the Linux server." >&2; exit 1; }
[[ "$EUID" -ne 0 ]] || { echo "Run as the normal deployment user, not root." >&2; exit 1; }

saved_value() {
  local key="$1"
  [[ -f "$PROJECT_DIR/.env" ]] || return 0
  sed -n "s/^${key}=//p" "$PROJECT_DIR/.env" | tail -n 1
}

LAN_IP="${LAN_IP:-$(saved_value MLFLOW_LAN_IP)}"
LAN_PORT="${LAN_PORT:-$(saved_value MLFLOW_LAN_PORT)}"
LAN_PORT="${LAN_PORT:-5000}"
[[ "$LAN_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || {
  echo "--lan-ip must be the server's office-LAN IPv4 address." >&2
  exit 2
}
[[ "$LAN_PORT" =~ ^[0-9]+$ ]] && ((LAN_PORT >= 1 && LAN_PORT <= 65535)) || {
  echo "--port must be a valid TCP port." >&2
  exit 2
}
[[ "$SSH_PORT" =~ ^[0-9]+$ ]] && ((SSH_PORT >= 1 && SSH_PORT <= 65535)) || {
  echo "--ssh-port must be a valid TCP port." >&2
  exit 2
}
if [[ "$CONFIGURE_FIREWALL" == true && ! "$LAN_CIDR" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]]; then
  echo "--lan-cidr is required with --configure-firewall." >&2
  exit 2
fi

docker_missing=false
if ! command -v docker >/dev/null 2>&1 || ! docker compose version >/dev/null 2>&1; then
  docker_missing=true
  [[ "$SKIP_BOOTSTRAP" == false ]] || { echo "Docker Engine and Compose are required." >&2; exit 1; }
fi
if [[ "$docker_missing" == true || "$CONFIGURE_FIREWALL" == true ]]; then
  bootstrap_args=()
  if [[ "$CONFIGURE_FIREWALL" == true ]]; then
    bootstrap_args+=(--configure-firewall --lan-cidr "$LAN_CIDR" --mlflow-port "$LAN_PORT" --ssh-port "$SSH_PORT")
  fi
  sudo bash "$PROJECT_DIR/scripts/bootstrap-ubuntu.sh" "${bootstrap_args[@]}"
fi

if ! docker info >/dev/null 2>&1; then
  echo "Docker is unavailable to $(id -un). Log out and reconnect if docker-group membership was just added." >&2
  exit 1
fi

bash "$PROJECT_DIR/scripts/init-config.sh"

set_env_value() {
  local key="$1" value="$2"
  if grep -q "^${key}=" "$PROJECT_DIR/.env"; then
    sed -i "s|^${key}=.*|${key}=${value}|" "$PROJECT_DIR/.env"
  else
    printf '\n%s=%s\n' "$key" "$value" >> "$PROJECT_DIR/.env"
  fi
}

set_env_value MLFLOW_LAN_IP "$LAN_IP"
set_env_value MLFLOW_LAN_PORT "$LAN_PORT"
set_env_value MINIO_VERSION "$(sed -n 's/^MINIO_VERSION=//p' "$PROJECT_DIR/.env.example" | tail -n 1)"

bash "$PROJECT_DIR/scripts/deploy.sh"

echo
echo "MLflow with MinIO is ready at http://${LAN_IP}:${LAN_PORT}"
echo "Username: admin"
echo "Password file: $PROJECT_DIR/secrets/mlflow_admin_password"
