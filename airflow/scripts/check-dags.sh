#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/common.sh"

require_command docker
require_initialized
"${COMPOSE[@]}" exec -T airflow-dag-processor airflow dags list-import-errors

