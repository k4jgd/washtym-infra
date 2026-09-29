#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
MODE="local"
DOMAIN=""
EMAIL=""
SSH_PORT=22
CONFIGURE_FIREWALL=false
SKIP_BOOTSTRAP=false

usage() {
  cat <<'EOF'
Usage:
  bash main.sh [options]

No-DNS deployment (default):
  bash main.sh --email admin@example.com

Public HTTPS deployment:
  bash main.sh --mode https --domain mlflow.example.com --email admin@example.com

Options:
  --mode local|https       Deployment mode (default: local)
  --domain DOMAIN          Required for HTTPS mode
  --email EMAIL            Required on first run
  --configure-firewall     Configure UFW during host bootstrap
  --ssh-port PORT          SSH port permitted by UFW (default: 22)
  --skip-bootstrap         Do not install Docker when it is missing
  -h, --help               Show this help

The local mode binds MLflow only to 127.0.0.1 and is accessed through SSH.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode) MODE="${2:-}"; shift 2 ;;
    --domain) DOMAIN="${2:-}"; shift 2 ;;
    --email) EMAIL="${2:-}"; shift 2 ;;
    --configure-firewall) CONFIGURE_FIREWALL=true; shift ;;
    --ssh-port) SSH_PORT="${2:-}"; shift 2 ;;
    --skip-bootstrap) SKIP_BOOTSTRAP=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

[[ "$MODE" == "local" || "$MODE" == "https" ]] || {
  echo "--mode must be local or https" >&2
  exit 2
}
[[ "$SSH_PORT" =~ ^[0-9]+$ ]] && ((SSH_PORT >= 1 && SSH_PORT <= 65535)) || {
  echo "Invalid SSH port: $SSH_PORT" >&2
  exit 2
}
[[ "$(uname -s)" == "Linux" ]] || {
  echo "This deployment must run on the Linux server." >&2
  exit 1
}
[[ "$EUID" -ne 0 ]] || {
  echo "Run main.sh as the normal deployment user, not root." >&2
  exit 1
}

env_value_if_present() {
  local key="$1"
  [[ -f "$PROJECT_DIR/.env" ]] || return 0
  sed -n "s/^${key}=//p" "$PROJECT_DIR/.env" | tail -n 1
}

bootstrap_if_needed() {
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    return 0
  fi

  if [[ "$SKIP_BOOTSTRAP" == true ]]; then
    echo "Docker Engine and the Compose plugin are required." >&2
    exit 1
  fi

  echo "==> Docker is missing; bootstrapping the Ubuntu host"
  bootstrap_args=()
  if [[ "$CONFIGURE_FIREWALL" == true ]]; then
    bootstrap_args+=(--configure-firewall --ssh-port "$SSH_PORT")
  fi
  sudo bash "$PROJECT_DIR/scripts/bootstrap-ubuntu.sh" "${bootstrap_args[@]}"
}

resume_with_docker_group_if_needed() {
  if docker info >/dev/null 2>&1; then
    return 0
  fi

  current_user="$(id -un)"
  if getent group docker | awk -F: -v user="$current_user" '
      $1 == "docker" {
        count=split($4, members, ",")
        for (i=1; i<=count; i++) if (members[i] == user) found=1
      }
      END {exit !found}
    '; then
    echo "Docker group membership was added, but this login session has not refreshed."
    echo "Log out, reconnect, and run the same main.sh command again."
  else
    echo "Docker is unavailable to user $current_user." >&2
    echo "Confirm Docker is running and add this user to the docker group." >&2
  fi
  exit 1
}

initialize_configuration() {
  existing_email="$(env_value_if_present ACME_EMAIL)"
  existing_domain="$(env_value_if_present DOMAIN)"
  EMAIL="${EMAIL:-$existing_email}"

  if [[ -z "$EMAIL" ]]; then
    echo "--email is required on the first run." >&2
    exit 2
  fi

  if [[ "$MODE" == "local" ]]; then
    DOMAIN=localhost
  else
    DOMAIN="${DOMAIN:-$existing_domain}"
    [[ -n "$DOMAIN" && "$DOMAIN" != "localhost" ]] || {
      echo "--domain is required for HTTPS mode." >&2
      exit 2
    }
  fi

  echo "==> Initializing configuration for $MODE mode"
  bash "$PROJECT_DIR/scripts/init-config.sh" --domain "$DOMAIN" --email "$EMAIL"
}

verify_local_binding() {
  local local_port container_id mapping
  local_port="$(env_value_if_present MLFLOW_LOCAL_PORT)"
  local_port="${local_port:-5000}"
  compose=(
    docker compose
    --project-directory "$PROJECT_DIR"
    --env-file "$PROJECT_DIR/.env"
    -f "$PROJECT_DIR/compose.yaml"
    -f "$PROJECT_DIR/compose.local.yaml"
  )

  container_id="$("${compose[@]}" ps -q mlflow)"
  [[ -n "$container_id" ]] || {
    echo "MLflow container was not created." >&2
    exit 1
  }

  mapping="$(docker port "$container_id" 5000/tcp 2>/dev/null || true)"
  if [[ "$mapping" != "127.0.0.1:${local_port}" ]]; then
    echo "Docker did not apply the required loopback port mapping." >&2
    echo "Expected: 127.0.0.1:${local_port}" >&2
    echo "Actual: ${mapping:-no published port}" >&2
    echo "Resolved Compose port configuration:" >&2
    "${compose[@]}" config --format json \
      | python3 -c 'import json,sys; print(json.load(sys.stdin)["services"]["mlflow"].get("ports"))' >&2
    echo "Container port configuration:" >&2
    docker inspect "$container_id" \
      --format 'Bindings={{json .HostConfig.PortBindings}} Ports={{json .NetworkSettings.Ports}}' >&2
    exit 1
  fi

  curl --fail --silent --show-error --max-time 15 \
    "http://127.0.0.1:${local_port}/health" >/dev/null

  echo
  echo "MLflow deployment completed successfully."
  echo "Server endpoint: http://127.0.0.1:${local_port} (loopback only)"
  echo "Open this tunnel from your workstation:"
  echo "  ssh -N -L ${local_port}:127.0.0.1:${local_port} $(id -un)@SERVER_IP"
  echo "Then browse to: http://localhost:${local_port}"
  echo "Admin username: admin"
  echo "Admin password file: $PROJECT_DIR/secrets/mlflow_admin_password"
}

cd "$PROJECT_DIR"
bootstrap_if_needed
initialize_configuration
resume_with_docker_group_if_needed

if [[ "$MODE" == "local" ]]; then
  if ! bash "$PROJECT_DIR/scripts/deploy-local.sh"; then
    echo "==> Local deployment did not pass its final check; inspecting the effective port binding" >&2
    verify_local_binding
    exit 0
  fi
  verify_local_binding
else
  bash "$PROJECT_DIR/scripts/deploy.sh"
  echo "MLflow deployment completed successfully at https://${DOMAIN}"
fi
