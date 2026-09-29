#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/common.sh"
require_command docker
require_command curl
require_initialized
require_shared_postgres

lan_ip="$(env_value AIRFLOW_LAN_IP)"
lan_port="$(env_value AIRFLOW_LAN_PORT)"
"${COMPOSE[@]}" ps
curl --fail --silent --show-error --max-time 20 \
  "http://${lan_ip}:${lan_port}/api/v2/monitor/health" >/dev/null \
  || die "Airflow health check failed."
echo "Airflow health check passed: http://${lan_ip}:${lan_port}"
"${COMPOSE[@]}" exec -T airflow-api-server airflow version
