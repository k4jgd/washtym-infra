#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PURGE_BACKUPS=false

usage() {
  cat <<'EOF'
Usage: bash reset-mlflow.sh [--purge-backups]

Permanently removes this MLflow deployment's containers, persistent database,
artifacts, generated image, private networks, .env, secrets, and runtime state.
Backups are preserved unless --purge-backups is explicitly supplied.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --purge-backups) PURGE_BACKUPS=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

[[ "$(uname -s)" == "Linux" ]] || {
  echo "Run this script on the Linux server." >&2
  exit 1
}
[[ "$EUID" -ne 0 ]] || {
  echo "Run this script as the normal deployment user, not root." >&2
  exit 1
}
[[ "$(basename -- "$PROJECT_DIR")" == "mlflow" ]] \
  && [[ -f "$PROJECT_DIR/compose.yaml" ]] \
  && [[ -d "$PROJECT_DIR/scripts" ]] || {
    echo "Safety check failed: this does not look like the MLflow project directory." >&2
    exit 1
  }
command -v docker >/dev/null 2>&1 || {
  echo "Docker is required so containers and volumes are not left behind." >&2
  exit 1
}
docker info >/dev/null 2>&1 || {
  echo "Docker is not running or this user cannot access it." >&2
  exit 1
}

echo "This will permanently delete:"
echo "  - Docker containers belonging to Compose project 'mlflow'"
echo "  - volumes mlflow_postgres_data, mlflow_artifacts, mlflow_caddy_data, mlflow_caddy_config"
echo "  - volume mlflow_minio_data"
echo "  - MLflow-only Docker networks and locally built MLflow/MinIO images"
echo "  - $PROJECT_DIR/.env"
echo "  - $PROJECT_DIR/secrets"
echo "  - $PROJECT_DIR/runtime"
if [[ "$PURGE_BACKUPS" == true ]]; then
  echo "  - $PROJECT_DIR/backups"
  confirmation="DELETE-MLFLOW-INCLUDING-BACKUPS"
else
  echo "Backups under $PROJECT_DIR/backups will be preserved."
  confirmation="DELETE-MLFLOW"
fi

read -r -p "Type ${confirmation} to continue: " answer
[[ "$answer" == "$confirmation" ]] || {
  echo "Reset cancelled."
  exit 1
}

mapfile -t container_ids < <(
  docker ps -aq --filter label=com.docker.compose.project=mlflow
)
if ((${#container_ids[@]} > 0)); then
  docker rm --force -- "${container_ids[@]}"
fi

for volume in \
  mlflow_postgres_data \
  mlflow_artifacts \
  mlflow_minio_data \
  mlflow_caddy_data \
  mlflow_caddy_config; do
  docker volume inspect "$volume" >/dev/null 2>&1 \
    && docker volume rm "$volume" >/dev/null \
    || true
done

for network in \
  mlflow_backend \
  mlflow_local_access \
  mlflow_vpn_access \
  mlflow_lan_access; do
  docker network inspect "$network" >/dev/null 2>&1 \
    && docker network rm "$network" >/dev/null \
    || true
done

mapfile -t image_ids < <(
  {
    docker image ls --quiet --filter reference='local/mlflow-server:*'
    docker image ls --quiet --filter reference='local/minio-server:*'
  } | sort -u
)
if ((${#image_ids[@]} > 0)); then
  docker image rm --force -- "${image_ids[@]}" >/dev/null
fi

cleanup_incomplete=false
if [[ -n "$(docker ps -aq --filter label=com.docker.compose.project=mlflow)" ]]; then
  echo "ERROR: one or more MLflow project containers remain." >&2
  cleanup_incomplete=true
fi
for volume in \
  mlflow_postgres_data \
  mlflow_artifacts \
  mlflow_minio_data \
  mlflow_caddy_data \
  mlflow_caddy_config; do
  if docker volume inspect "$volume" >/dev/null 2>&1; then
    echo "ERROR: volume remains: $volume" >&2
    cleanup_incomplete=true
  fi
done
for network in \
  mlflow_backend \
  mlflow_local_access \
  mlflow_vpn_access \
  mlflow_lan_access; do
  if docker network inspect "$network" >/dev/null 2>&1; then
    echo "ERROR: network remains: $network" >&2
    cleanup_incomplete=true
  fi
done
if [[ "$cleanup_incomplete" == true ]]; then
  echo "Docker cleanup is incomplete; generated configuration was preserved for recovery." >&2
  exit 1
fi

rm -f -- "$PROJECT_DIR/.env"
rm -rf -- "$PROJECT_DIR/secrets" "$PROJECT_DIR/runtime"
if [[ "$PURGE_BACKUPS" == true ]]; then
  rm -rf -- "$PROJECT_DIR/backups"
fi

echo "MLflow reset completed."
if [[ "$PURGE_BACKUPS" == false ]]; then
  echo "Backups were preserved at: $PROJECT_DIR/backups"
fi
echo "Run setup-lan.sh to create a fresh LAN-only deployment."
