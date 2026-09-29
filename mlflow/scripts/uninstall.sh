#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/common.sh"

PURGE=false
if [[ "${1:-}" == "--purge-data" ]]; then
  PURGE=true
elif [[ $# -gt 0 ]]; then
  echo "Usage: $0 [--purge-data]" >&2
  exit 2
fi

require_command docker
require_initialized

if [[ "$PURGE" == false ]]; then
  "${COMPOSE[@]}" down --remove-orphans
  echo "Containers and networks removed. Persistent volumes and local backups were preserved."
  exit 0
fi

echo "WARNING: This permanently deletes MLflow database, artifacts, and Caddy state."
echo "Local backup files under $PROJECT_DIR/backups are preserved."
read -r -p "Type PURGE-MLFLOW-DATA to continue: " answer
[[ "$answer" == "PURGE-MLFLOW-DATA" ]] || die "Purge cancelled."

"${COMPOSE[@]}" down --volumes --remove-orphans
rm -f -- "$PROJECT_DIR/runtime/auth-bootstrap-complete"
echo "MLflow containers, networks, and persistent volumes were deleted."
