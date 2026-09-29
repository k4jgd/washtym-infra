#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/common.sh"

require_command docker
require_command curl
require_initialized

lan_ip="$(env_value MLFLOW_LAN_IP)"
lan_port="$(env_value MLFLOW_LAN_PORT)"

"${COMPOSE[@]}" ps

curl --fail --silent --show-error --max-time 15 \
  "http://${lan_ip}:${lan_port}/health" >/dev/null \
  || die "MLflow health check failed at http://${lan_ip}:${lan_port}."

echo "MLflow health check passed: http://${lan_ip}:${lan_port}"
"${COMPOSE[@]}" exec -T mlflow mlflow --version
echo "Artifact destination: $("${COMPOSE[@]}" exec -T mlflow printenv MLFLOW_ARTIFACTS_DESTINATION)"
