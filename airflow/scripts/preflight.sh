#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/common.sh"

require_command docker
require_command getent
require_command nproc
require_command awk
require_initialized

[[ "$(uname -s)" == "Linux" ]] || die "Deployment requires a Linux server."
docker info >/dev/null 2>&1 || die "Docker Engine is not running or this user cannot access it."
docker compose version >/dev/null 2>&1 || die "The Docker Compose plugin is unavailable."
gateway_is_running || die "The MLflow Caddy gateway is not running. Deploy MLflow first."

domain="$(env_value DOMAIN)"
[[ "$domain" != "airflow.example.com" ]] || die "The example DOMAIN is still configured."
getent ahosts "$domain" >/dev/null 2>&1 || die "DNS does not resolve for $domain."

mlflow_domain="$(sed -n 's/^DOMAIN=//p' "$MLFLOW_DIR/.env" | tail -n 1)"
[[ "$domain" != "$mlflow_domain" ]] || die "Airflow and MLflow must use different hostnames."

cores="$(nproc)"
memory_kib="$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)"
memory_gib=$((memory_kib / 1024 / 1024))
disk_kib="$(df -Pk "$PROJECT_DIR" | awk 'NR == 2 {print $4}')"
disk_gib=$((disk_kib / 1024 / 1024))

((cores >= 4)) || echo "WARNING: only $cores CPU cores detected; 4 or more are recommended." >&2
((memory_gib >= 8)) || echo "WARNING: Airflow recommends at least 4 GB by itself; this shared host should have at least 8 GB." >&2
((disk_gib >= 20)) || echo "WARNING: only about ${disk_gib} GiB free; logs and backups may exhaust it." >&2

docker network inspect localinfra_edge >/dev/null 2>&1 || die "Shared Docker network localinfra_edge is missing. Redeploy MLflow."
"${COMPOSE[@]}" config --quiet

echo "Airflow preflight checks passed."
echo "CPU cores: $cores"
echo "RAM: approximately ${memory_gib} GiB"
echo "Free disk: approximately ${disk_gib} GiB"
echo "DNS: $domain"

