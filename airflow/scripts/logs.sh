#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/common.sh"

require_command docker
require_initialized
if (( $# > 0 )); then
  "${COMPOSE[@]}" logs --tail="${LOG_LINES:-200}" -f "$@"
else
  "${COMPOSE[@]}" logs --tail="${LOG_LINES:-200}" -f
fi

