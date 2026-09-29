#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/common.sh"

require_command docker
require_command curl
require_initialized

local_port="$(sed -n 's/^MLFLOW_LOCAL_PORT=//p' "$PROJECT_DIR/.env" | tail -n 1)"
local_port="${local_port:-5000}"

"${COMPOSE[@]}" ps

echo
if curl --fail --silent --show-error --max-time 15 \
    "http://127.0.0.1:${local_port}/health"; then
  echo
  echo "Loopback health check passed."
else
  echo "Loopback health check failed." >&2
  exit 1
fi

"${COMPOSE[@]}" exec -T mlflow mlflow --version
