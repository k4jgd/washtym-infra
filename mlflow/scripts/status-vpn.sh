#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/common.sh"

require_command docker
require_command curl
require_initialized

vpn_ip="$(env_value MLFLOW_VPN_IP)"
vpn_port="$(sed -n 's/^MLFLOW_VPN_PORT=//p' "$PROJECT_DIR/.env" | tail -n 1)"
vpn_port="${vpn_port:-5000}"

"${COMPOSE[@]}" ps

echo
if curl --fail --silent --show-error --max-time 15 \
    "http://${vpn_ip}:${vpn_port}/health"; then
  echo
  echo "VPN health check passed."
else
  echo "VPN health check failed." >&2
  exit 1
fi

"${COMPOSE[@]}" exec -T mlflow mlflow --version
