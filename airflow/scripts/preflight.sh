#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/common.sh"

require_command docker
require_command ip
require_command nproc
require_command awk
require_initialized

[[ "$(uname -s)" == "Linux" ]] || die "Deployment requires Linux."
docker info >/dev/null 2>&1 || die "Docker is unavailable."
docker compose version >/dev/null 2>&1 || die "Docker Compose is unavailable."
require_shared_postgres
[[ "$(env_value POSTGRES_DB)" == "$(postgres_env_value AIRFLOW_DB)" ]] || die "Airflow database name mismatch."
[[ "$(env_value POSTGRES_USER)" == "$(postgres_env_value AIRFLOW_DB_USER)" ]] || die "Airflow database user mismatch."

lan_ip="$(env_value AIRFLOW_LAN_IP)"
lan_port="$(env_value AIRFLOW_LAN_PORT)"
[[ "$lan_port" =~ ^[0-9]+$ ]] && ((lan_port >= 1 && lan_port <= 65535)) || die "Invalid Airflow port."
lan_interface="$(ip -4 -o addr show | awk -v address="$lan_ip" '{split($4,p,"/")} p[1] == address {print $2; exit}')"
[[ -n "$lan_interface" ]] || die "AIRFLOW_LAN_IP $lan_ip is not assigned to this server."

cores="$(nproc)"
memory_kib="$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)"
memory_gib=$((memory_kib / 1024 / 1024))
disk_kib="$(df -Pk "$PROJECT_DIR" | awk 'NR == 2 {print $4}')"
disk_gib=$((disk_kib / 1024 / 1024))
((cores >= 4)) || echo "WARNING: only $cores CPU cores detected." >&2
((memory_gib >= 8)) || echo "WARNING: Airflow and MLflow share this host; 8 GB is the minimum practical size." >&2
((disk_gib >= 20)) || echo "WARNING: only about ${disk_gib} GiB free." >&2

if [[ -z "$("${COMPOSE[@]}" ps -q airflow-api-server 2>/dev/null || true)" ]] && command -v ss >/dev/null 2>&1; then
  if ss -H -ltn | awk -v endpoint="${lan_ip}:${lan_port}" '$4 == endpoint {found=1} END {exit !found}'; then
    die "LAN endpoint ${lan_ip}:${lan_port} is already in use."
  fi
fi

"${COMPOSE[@]}" config --quiet
echo "Airflow preflight checks passed."
echo "CPU cores: $cores"
echo "RAM: approximately ${memory_gib} GiB"
echo "LAN interface: $lan_interface"
echo "Airflow address: http://${lan_ip}:${lan_port}"
