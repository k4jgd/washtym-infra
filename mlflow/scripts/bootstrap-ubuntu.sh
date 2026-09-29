#!/usr/bin/env bash
set -Eeuo pipefail

SSH_PORT=22
APPLICATION_PORT=5000
LAN_CIDR=""
CONFIGURE_FIREWALL=false

usage() {
  cat <<'EOF'
Usage: sudo ./scripts/bootstrap-ubuntu.sh [options]

Installs Docker Engine, the Compose plugin, security updates, and basic tools.
Firewall changes are opt-in to avoid locking out remote administration.

  --configure-firewall  Enable UFW for SSH and MLflow
  --lan-cidr CIDR       Office subnet allowed to reach MLflow
  --application-port PORT  Application HTTP port (default: 5000)
  --ssh-port PORT       SSH port (default: 22)
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --configure-firewall) CONFIGURE_FIREWALL=true; shift ;;
    --lan-cidr) LAN_CIDR="${2:-}"; shift 2 ;;
    --application-port|--mlflow-port) APPLICATION_PORT="${2:-}"; shift 2 ;;
    --ssh-port) SSH_PORT="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

[[ "$EUID" -eq 0 ]] || { echo "Run this script with sudo." >&2; exit 1; }
if [[ ! "$SSH_PORT" =~ ^[0-9]+$ ]] || ((SSH_PORT < 1 || SSH_PORT > 65535)); then
  echo "Invalid SSH port: $SSH_PORT" >&2
  exit 2
fi
if [[ ! "$APPLICATION_PORT" =~ ^[0-9]+$ ]] || ((APPLICATION_PORT < 1 || APPLICATION_PORT > 65535)); then
  echo "Invalid application port: $APPLICATION_PORT" >&2
  exit 2
fi
if [[ "$CONFIGURE_FIREWALL" == true && ! "$LAN_CIDR" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]]; then
  echo "--lan-cidr is required when configuring the firewall." >&2
  exit 2
fi
[[ -r /etc/os-release ]] || { echo "Cannot identify operating system." >&2; exit 1; }
. /etc/os-release
[[ "${ID:-}" == "ubuntu" ]] || { echo "This script supports Ubuntu only." >&2; exit 1; }

apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y \
  ca-certificates curl gnupg openssl ufw unattended-upgrades

install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  | gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg

ARCH="$(dpkg --print-architecture)"
CODENAME="${UBUNTU_CODENAME:-$VERSION_CODENAME}"
printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu %s stable\n' \
  "$ARCH" "$CODENAME" > /etc/apt/sources.list.d/docker.list

apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y \
  docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
systemctl enable --now docker

LOGIN_USER="${SUDO_USER:-}"
if [[ -n "$LOGIN_USER" && "$LOGIN_USER" != "root" ]]; then
  usermod -aG docker "$LOGIN_USER"
  echo "Added $LOGIN_USER to the docker group; log out and back in before deploying."
fi

dpkg-reconfigure -f noninteractive unattended-upgrades

if [[ "$CONFIGURE_FIREWALL" == true ]]; then
  ufw default deny incoming
  ufw default allow outgoing
  ufw allow "${SSH_PORT}/tcp" comment SSH
  ufw allow from "$LAN_CIDR" to any port "$APPLICATION_PORT" proto tcp comment LocalInfra-LAN
  ufw --force enable
  ufw status verbose
else
  echo "Firewall was not changed. Re-run with --configure-firewall after confirming the SSH port."
fi

docker --version
docker compose version
