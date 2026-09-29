#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
MLFLOW_BOOTSTRAP="$(cd -- "$SCRIPT_DIR/../../mlflow/scripts" && pwd)/bootstrap-ubuntu.sh"
[[ -f "$MLFLOW_BOOTSTRAP" ]] || {
  echo "Shared Ubuntu bootstrap script not found: $MLFLOW_BOOTSTRAP" >&2
  exit 1
}
exec bash "$MLFLOW_BOOTSTRAP" "$@"

