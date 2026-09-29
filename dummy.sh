#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LAN_IP=""
MLFLOW_PORT=5000
AIRFLOW_PORT=8080
ASSUME_YES=false

usage() {
  cat <<'EOF'
Usage:
  bash dummy.sh --lan-ip ADDRESS [options]

Options:
  --lan-ip ADDRESS       Static office-LAN IPv4 address of this server
  --mlflow-port PORT     MLflow HTTP port (default: 5000)
  --airflow-port PORT    Airflow HTTP port (default: 8080)
  --yes                  Skip the REDEPLOY-LOCALINFRA confirmation
  -h, --help             Show help

This script removes only containers owned by the mlflow, airflow, and
shared-postgres Compose projects. It preserves Docker volumes, application
secrets, configuration, DAGs, model artifacts, logs, and backups.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --lan-ip) LAN_IP="${2:-}"; shift 2 ;;
    --mlflow-port) MLFLOW_PORT="${2:-}"; shift 2 ;;
    --airflow-port) AIRFLOW_PORT="${2:-}"; shift 2 ;;
    --yes) ASSUME_YES=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

[[ "$(uname -s)" == "Linux" ]] || { echo "Run this script on the Linux server." >&2; exit 1; }
[[ "$EUID" -ne 0 ]] || { echo "Run as the normal deployment user, not root." >&2; exit 1; }
[[ "$LAN_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || { echo "A valid --lan-ip is required." >&2; exit 2; }
for port in "$MLFLOW_PORT" "$AIRFLOW_PORT"; do
  [[ "$port" =~ ^[0-9]+$ ]] && ((port >= 1 && port <= 65535)) \
    || { echo "Invalid TCP port: $port" >&2; exit 2; }
done
[[ "$MLFLOW_PORT" != "$AIRFLOW_PORT" ]] || { echo "MLflow and Airflow ports must differ." >&2; exit 2; }

for required in \
  "$ROOT_DIR/postgres/main.sh" \
  "$ROOT_DIR/mlflow/main.sh" \
  "$ROOT_DIR/airflow/main.sh"; do
  [[ -f "$required" ]] || { echo "Required deployment script is missing: $required" >&2; exit 1; }
done
command -v docker >/dev/null 2>&1 || { echo "Docker is required." >&2; exit 1; }
docker info >/dev/null 2>&1 || { echo "Docker is unavailable to $(id -un)." >&2; exit 1; }

shared_volume_existed=false
docker volume inspect shared_postgres_data >/dev/null 2>&1 && shared_volume_existed=true

echo "Containers selected for replacement:"
found=false
for project in mlflow airflow shared-postgres; do
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    found=true
    echo "  $line"
  done < <(docker ps -a \
    --filter "label=com.docker.compose.project=${project}" \
    --format '{{.Names}} ({{.Status}})')
done
[[ "$found" == true ]] || echo "  none"

echo
echo "No Docker volume, database volume, model artifact, DAG, secret, or backup will be deleted."
legacy_volumes=()
for volume in mlflow_postgres_data airflow_postgres_data; do
  docker volume inspect "$volume" >/dev/null 2>&1 && legacy_volumes+=("$volume")
done
if ((${#legacy_volumes[@]} > 0)); then
  echo "WARNING: legacy standalone database volume(s) detected: ${legacy_volumes[*]}" >&2
  echo "They will be preserved but are not automatically imported into shared PostgreSQL." >&2
fi

if [[ "$ASSUME_YES" != true ]]; then
  read -r -p "Type REDEPLOY-LOCALINFRA to continue: " answer
  [[ "$answer" == "REDEPLOY-LOCALINFRA" ]] || { echo "Redeployment cancelled."; exit 1; }
fi

container_ids=()
for project in mlflow airflow shared-postgres; do
  while IFS= read -r id; do
    [[ -n "$id" ]] && container_ids+=("$id")
  done < <(docker ps -aq --filter "label=com.docker.compose.project=${project}")
done

if ((${#container_ids[@]} > 0)); then
  echo "==> Gracefully stopping existing LocalInfra containers"
  docker stop --time 30 "${container_ids[@]}" >/dev/null
  echo "==> Removing existing LocalInfra containers"
  docker rm "${container_ids[@]}" >/dev/null
fi

# A new shared database contains no bootstrap records. Clear only initialization
# markers so the existing generated passwords create fresh administrator users.
if [[ "$shared_volume_existed" != true ]]; then
  rm -f -- \
    "$ROOT_DIR/mlflow/runtime/auth-bootstrap-complete" \
    "$ROOT_DIR/airflow/runtime/initialized"
fi

echo "==> Starting shared PostgreSQL"
bash "$ROOT_DIR/postgres/main.sh"

echo "==> Deploying MLflow"
bash "$ROOT_DIR/mlflow/main.sh" \
  --lan-ip "$LAN_IP" \
  --port "$MLFLOW_PORT" \
  --skip-bootstrap

echo "==> Deploying Airflow"
bash "$ROOT_DIR/airflow/main.sh" \
  --lan-ip "$LAN_IP" \
  --port "$AIRFLOW_PORT" \
  --skip-bootstrap

echo "==> Final status"
bash "$ROOT_DIR/postgres/scripts/status.sh"
bash "$ROOT_DIR/mlflow/scripts/status.sh"
bash "$ROOT_DIR/airflow/scripts/status.sh"

echo
echo "Redeployment completed."
echo "MLflow: http://${LAN_IP}:${MLFLOW_PORT}"
echo "Airflow: http://${LAN_IP}:${AIRFLOW_PORT}"
