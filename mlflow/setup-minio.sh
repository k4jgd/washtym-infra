#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CONFIRM_SWITCH=false
main_args=()

usage() {
  cat <<'EOF'
Usage:
  bash setup-minio.sh [--confirm-switch] [main.sh LAN/VPN/local/HTTPS options]

Fresh LAN example:
  bash setup-minio.sh --mode lan --lan-ip 192.168.1.50 --port 5000 \
    --email admin@example.com

If an existing deployment uses the local mlflow_artifacts volume, this script
refuses to switch because existing files are not migrated automatically. Back
up and reset first, or pass --confirm-switch to accept that old local artifacts
will not appear in MinIO.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --confirm-switch) CONFIRM_SWITCH=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) main_args+=("$1"); shift ;;
  esac
done

current_store=""
if [[ -f "$PROJECT_DIR/.env" ]]; then
  current_store="$(sed -n 's/^ARTIFACT_STORE=//p' "$PROJECT_DIR/.env" | tail -n 1)"
fi

if [[ -f "$PROJECT_DIR/runtime/auth-bootstrap-complete" ]] \
    && [[ "$current_store" != "minio" ]] \
    && [[ "$CONFIRM_SWITCH" != true ]]; then
  echo "An existing MLflow deployment is using local artifact storage." >&2
  echo "Existing artifact files are not automatically migrated to MinIO." >&2
  echo "Run scripts/backup.sh and reset-mlflow.sh first, or rerun with" >&2
  echo "--confirm-switch if losing access to existing local artifacts is acceptable." >&2
  exit 1
fi

exec bash "$PROJECT_DIR/main.sh" --artifact-store minio "${main_args[@]}"

