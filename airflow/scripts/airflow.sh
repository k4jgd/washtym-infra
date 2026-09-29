#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/common.sh"

require_command docker
require_initialized
(( $# > 0 )) || die "Usage: $0 AIRFLOW_CLI_ARGUMENTS..."
"${COMPOSE[@]}" exec airflow-api-server airflow "$@"

