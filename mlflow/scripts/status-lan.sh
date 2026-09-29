#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/common.sh"

COMPOSE+=( -f "$PROJECT_DIR/compose.lan.yaml" )

require_command docker
require_command curl
require_initialized

lan_ip="$(env_value MLFLOW_LAN_IP)"
lan_port="$(sed -n 's/^MLFLOW_LAN_PORT=//p' "$PROJECT_DIR/.env" | tail -n 1)"
lan_port="${lan_port:-5000}"

"${COMPOSE[@]}" ps

echo
if curl --fail --silent --show-error --max-time 15 \
    "http://${lan_ip}:${lan_port}/health"; then
  echo
  echo "LAN health check passed."
else
  echo "LAN health check failed." >&2
  exit 1
fi

"${COMPOSE[@]}" exec -T mlflow mlflow --version

