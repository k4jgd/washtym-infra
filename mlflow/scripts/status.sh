#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/common.sh"

require_command docker
require_command curl
require_initialized

domain="$(env_value DOMAIN)"
"${COMPOSE[@]}" ps

echo
if curl --fail --silent --show-error --max-time 15 "https://${domain}/health"; then
  echo
  echo "Public health check passed."
else
  echo "Public health check failed." >&2
  exit 1
fi

version="$("${COMPOSE[@]}" exec -T mlflow mlflow --version)"
echo "$version"
