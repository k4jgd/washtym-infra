#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
POSTGRES_DIR="$(cd -- "$PROJECT_DIR/../postgres" && pwd)"
PURGE_BACKUPS=false

if [[ "${1:-}" == "--purge-backups" ]]; then
  PURGE_BACKUPS=true
elif [[ $# -gt 0 ]]; then
  echo "Usage: bash reset-airflow.sh [--purge-backups]" >&2
  exit 2
fi

[[ "$(uname -s)" == "Linux" ]] || { echo "Run this on the Linux server." >&2; exit 1; }
[[ "$EUID" -ne 0 ]] || { echo "Run as the normal deployment user." >&2; exit 1; }
[[ "$(basename -- "$PROJECT_DIR")" == "airflow" && -f "$PROJECT_DIR/compose.yaml" ]] \
  || { echo "Safety check failed: not the Airflow project directory." >&2; exit 1; }
command -v docker >/dev/null 2>&1 || { echo "Docker is required." >&2; exit 1; }
docker info >/dev/null 2>&1 || { echo "Docker is unavailable." >&2; exit 1; }
[[ -f "$POSTGRES_DIR/scripts/reset-database.sh" && -f "$POSTGRES_DIR/.env" ]] \
  || { echo "Shared PostgreSQL configuration or reset helper is missing." >&2; exit 1; }

echo "This permanently removes only Airflow application state:"
echo "  - Airflow containers and locally built image"
echo "  - only the Airflow database inside shared PostgreSQL"
echo "  - Airflow private networks, logs, .env, secrets, and runtime state"
echo "  - any legacy airflow_postgres_data volume"
echo "Shared PostgreSQL, its volume, and the MLflow database are preserved."
if [[ "$PURGE_BACKUPS" == true ]]; then
  confirmation="DELETE-AIRFLOW-INCLUDING-BACKUPS"
else
  confirmation="DELETE-AIRFLOW"
  echo "Backups are preserved."
fi
read -r -p "Type ${confirmation} to continue: " answer
[[ "$answer" == "$confirmation" ]] || { echo "Reset cancelled."; exit 1; }

mapfile -t container_ids < <(docker ps -aq --filter label=com.docker.compose.project=airflow)
if ((${#container_ids[@]} > 0)); then
  docker rm --force -- "${container_ids[@]}"
fi

bash "$POSTGRES_DIR/scripts/reset-database.sh" --application airflow --confirm

docker volume inspect airflow_postgres_data >/dev/null 2>&1 \
  && docker volume rm airflow_postgres_data >/dev/null \
  || true

for network in airflow_backend airflow_task_egress airflow_lan_access; do
  docker network inspect "$network" >/dev/null 2>&1 && docker network rm "$network" >/dev/null || true
done
mapfile -t image_ids < <(docker image ls --quiet --filter reference='local/airflow-server:*' | sort -u)
if ((${#image_ids[@]} > 0)); then
  docker image rm --force -- "${image_ids[@]}" >/dev/null
fi

rm -f -- "$PROJECT_DIR/.env"
rm -rf -- "$PROJECT_DIR/secrets" "$PROJECT_DIR/runtime"
find "$PROJECT_DIR/logs" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
if [[ "$PURGE_BACKUPS" == true ]]; then
  rm -rf -- "$PROJECT_DIR/backups"
fi

echo "Airflow reset completed. Shared PostgreSQL and MLflow data were preserved."
echo "Run main.sh to deploy Airflow again."
