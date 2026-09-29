#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/common.sh"

require_command docker
require_command curl
require_initialized

domain="$(env_value DOMAIN)"
"${COMPOSE[@]}" ps

echo
curl --fail --silent --show-error --max-time 20 \
  "https://${domain}/api/v2/monitor/health"
echo
"${COMPOSE[@]}" exec -T airflow-api-server airflow version

