#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LAN_IP=""
LAN_PORT=""
LAN_CIDR=""
SSH_PORT=22
CONFIGURE_FIREWALL=false
SKIP_BOOTSTRAP=false

usage() {
  cat <<'EOF'
Usage:
  bash main.sh --lan-ip ADDRESS [options]

Example:
  bash main.sh --lan-ip 192.168.0.48 --port 8080

Options:
  --lan-ip ADDRESS         Static office-LAN IPv4 address of this server
  --port PORT              Airflow HTTP port (default: 8080)
  --configure-firewall     Allow the Airflow port only from --lan-cidr
  --lan-cidr CIDR          Office subnet, e.g. 192.168.0.0/24
  --ssh-port PORT          SSH port retained by UFW (default: 22)
  --skip-bootstrap         Fail instead of installing Docker when missing
  -h, --help               Show help
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
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

[[ "$(uname -s)" == "Linux" ]] || { echo "Run this on the Linux server." >&2; exit 1; }
[[ "$EUID" -ne 0 ]] || { echo "Run as the normal deployment user." >&2; exit 1; }

saved_value() {
  [[ -f "$PROJECT_DIR/.env" ]] || return 0
  sed -n "s/^$1=//p" "$PROJECT_DIR/.env" | tail -n 1
}
LAN_IP="${LAN_IP:-$(saved_value AIRFLOW_LAN_IP)}"
LAN_PORT="${LAN_PORT:-$(saved_value AIRFLOW_LAN_PORT)}"
LAN_PORT="${LAN_PORT:-8080}"
[[ "$LAN_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || { echo "A valid --lan-ip is required." >&2; exit 2; }
[[ "$LAN_PORT" =~ ^[0-9]+$ ]] && ((LAN_PORT >= 1 && LAN_PORT <= 65535)) || { echo "Invalid --port." >&2; exit 2; }
[[ "$SSH_PORT" =~ ^[0-9]+$ ]] && ((SSH_PORT >= 1 && SSH_PORT <= 65535)) || { echo "Invalid --ssh-port." >&2; exit 2; }
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
  args=()
  if [[ "$CONFIGURE_FIREWALL" == true ]]; then
    args+=(--configure-firewall --lan-cidr "$LAN_CIDR" --application-port "$LAN_PORT" --ssh-port "$SSH_PORT")
  fi
  sudo bash "$PROJECT_DIR/scripts/bootstrap-ubuntu.sh" "${args[@]}"
fi
docker info >/dev/null 2>&1 || {
  echo "Docker is unavailable to $(id -un). Log out and reconnect if group membership was just added." >&2
  exit 1
}

echo "==> Starting the shared PostgreSQL data tier"
bash "$PROJECT_DIR/../postgres/main.sh"
bash "$PROJECT_DIR/scripts/init-config.sh"

set_env_value() {
  if grep -q "^$1=" "$PROJECT_DIR/.env"; then
    sed -i "s|^$1=.*|$1=$2|" "$PROJECT_DIR/.env"
  else
    printf '\n%s=%s\n' "$1" "$2" >> "$PROJECT_DIR/.env"
  fi
}
set_env_value AIRFLOW_LAN_IP "$LAN_IP"
set_env_value AIRFLOW_LAN_PORT "$LAN_PORT"
set_env_value POSTGRES_DB "$(sed -n 's/^AIRFLOW_DB=//p' "$PROJECT_DIR/../postgres/.env" | tail -n 1)"
set_env_value POSTGRES_USER "$(sed -n 's/^AIRFLOW_DB_USER=//p' "$PROJECT_DIR/../postgres/.env" | tail -n 1)"

bash "$PROJECT_DIR/scripts/deploy.sh"
echo
echo "Airflow is ready at http://${LAN_IP}:${LAN_PORT}"
echo "Username: admin"
echo "Password file: $PROJECT_DIR/secrets/airflow_admin_password"
