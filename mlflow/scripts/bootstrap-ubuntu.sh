#!/usr/bin/env bash
set -Eeuo pipefail

SSH_PORT=22
CONFIGURE_FIREWALL=false

usage() {
  cat <<'EOF'
Usage: sudo ./scripts/bootstrap-ubuntu.sh [--configure-firewall] [--ssh-port PORT]

Installs Docker Engine, the Compose plugin, security updates, and basic tools.
Firewall changes are opt-in to avoid locking out remote administration.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --configure-firewall) CONFIGURE_FIREWALL=true; shift ;;
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
  ufw allow 80/tcp comment HTTP
  ufw allow 443/tcp comment HTTPS
  ufw allow 443/udp comment HTTP3
  ufw --force enable
  ufw status verbose
else
  echo "Firewall was not changed. Re-run with --configure-firewall after confirming the SSH port."
fi

docker --version
docker compose version
