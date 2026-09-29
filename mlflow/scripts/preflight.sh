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

domain="$(env_value DOMAIN)"
[[ "$domain" != "mlflow.example.com" ]] || die "The example DOMAIN is still configured."
getent ahosts "$domain" >/dev/null 2>&1 || die "DNS does not resolve for $domain."

cores="$(nproc)"
memory_kib="$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)"
memory_gib=$((memory_kib / 1024 / 1024))
disk_kib="$(df -Pk "$PROJECT_DIR" | awk 'NR == 2 {print $4}')"
disk_gib=$((disk_kib / 1024 / 1024))

((cores >= 4)) || echo "WARNING: only $cores CPU cores detected; 4 or more are recommended." >&2
((memory_gib >= 6)) || echo "WARNING: only about ${memory_gib} GiB RAM detected; 8 GiB is recommended for the shared host." >&2
((disk_gib >= 20)) || echo "WARNING: only about ${disk_gib} GiB free; artifact and backup growth may exhaust it." >&2

if [[ -z "$("${COMPOSE[@]}" ps -q caddy 2>/dev/null || true)" ]] && command -v ss >/dev/null 2>&1; then
  listeners="$(ss -H -ltn | awk '$4 ~ /:80$/ || $4 ~ /:443$/ {print}')"
  [[ -z "$listeners" ]] || {
    echo "$listeners" >&2
    die "Ports 80 or 443 are already in use."
  }
fi

"${COMPOSE[@]}" config --quiet

echo "Preflight checks passed."
echo "CPU cores: $cores"
echo "RAM: approximately ${memory_gib} GiB"
echo "Free disk: approximately ${disk_gib} GiB"
echo "DNS: $domain"

