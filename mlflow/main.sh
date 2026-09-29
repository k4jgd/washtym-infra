#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
MODE=""
DOMAIN=""
EMAIL=""
VPN_IP=""
LAN_IP=""
SERVICE_PORT=""
ARTIFACT_STORE=""
SSH_PORT=22
CONFIGURE_FIREWALL=false
SKIP_BOOTSTRAP=false

usage() {
  cat <<'EOF'
Usage:
  bash main.sh [options]

No-DNS deployment (default):
  bash main.sh --email admin@example.com

VPN deployment:
  bash main.sh --mode vpn --vpn-ip 100.64.0.10 --port 5000 --email admin@example.com

Office LAN HTTP deployment:
  bash main.sh --mode lan --lan-ip 192.168.1.50 --port 5000 --email admin@example.com

Public HTTPS deployment:
  bash main.sh --mode https --domain mlflow.example.com --email admin@example.com

Options:
  --mode MODE              local, lan, vpn, or https (default: saved mode or local)
  --domain DOMAIN          Required for HTTPS mode
  --lan-ip ADDRESS         Server office-LAN interface IPv4 address
  --vpn-ip ADDRESS         Server VPN interface IPv4 address
  --port PORT              LAN/VPN HTTP port (default: 5000)
  --artifact-store STORE   local or minio (default: saved value or local)
  --email EMAIL            Required on first run
  --configure-firewall     Configure UFW during host bootstrap
  --ssh-port PORT          SSH port permitted by UFW (default: 22)
  --skip-bootstrap         Do not install Docker when it is missing
  -h, --help               Show this help

Local mode uses an SSH tunnel. LAN/VPN modes bind only to the supplied IP.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode) MODE="${2:-}"; shift 2 ;;
    --domain) DOMAIN="${2:-}"; shift 2 ;;
    --lan-ip) LAN_IP="${2:-}"; shift 2 ;;
    --vpn-ip) VPN_IP="${2:-}"; shift 2 ;;
    --port) SERVICE_PORT="${2:-}"; shift 2 ;;
    --artifact-store) ARTIFACT_STORE="${2:-}"; shift 2 ;;
    --email) EMAIL="${2:-}"; shift 2 ;;
    --configure-firewall) CONFIGURE_FIREWALL=true; shift ;;
    --ssh-port) SSH_PORT="${2:-}"; shift 2 ;;
    --skip-bootstrap) SKIP_BOOTSTRAP=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

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

set_env_value() {
  local key="$1"
  local value="$2"
  if grep -q "^${key}=" "$PROJECT_DIR/.env"; then
    sed -i "s|^${key}=.*|${key}=${value}|" "$PROJECT_DIR/.env"
  else
    printf '\n%s=%s\n' "$key" "$value" >> "$PROJECT_DIR/.env"
  fi
}

MODE="${MODE:-$(env_value_if_present DEPLOYMENT_MODE)}"
MODE="${MODE:-local}"
ARTIFACT_STORE="${ARTIFACT_STORE:-$(env_value_if_present ARTIFACT_STORE)}"
ARTIFACT_STORE="${ARTIFACT_STORE:-local}"
[[ "$MODE" == "local" || "$MODE" == "lan" || "$MODE" == "vpn" || "$MODE" == "https" ]] || {
  echo "--mode must be local, lan, vpn, or https" >&2
  exit 2
}
[[ "$ARTIFACT_STORE" == "local" || "$ARTIFACT_STORE" == "minio" ]] || {
  echo "--artifact-store must be local or minio" >&2
  exit 2
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
  local existing_email existing_domain existing_lan_ip existing_lan_port
  local existing_vpn_ip existing_vpn_port
  existing_email="$(env_value_if_present ACME_EMAIL)"
  existing_domain="$(env_value_if_present DOMAIN)"
  existing_lan_ip="$(env_value_if_present MLFLOW_LAN_IP)"
  existing_lan_port="$(env_value_if_present MLFLOW_LAN_PORT)"
  existing_vpn_ip="$(env_value_if_present MLFLOW_VPN_IP)"
  existing_vpn_port="$(env_value_if_present MLFLOW_VPN_PORT)"
  EMAIL="${EMAIL:-$existing_email}"

  if [[ -z "$EMAIL" ]]; then
    echo "--email is required on the first run." >&2
    exit 2
  fi

  if [[ "$MODE" == "local" ]]; then
    DOMAIN=localhost
  elif [[ "$MODE" == "lan" ]]; then
    LAN_IP="${LAN_IP:-$existing_lan_ip}"
    SERVICE_PORT="${SERVICE_PORT:-${existing_lan_port:-5000}}"
    [[ "$LAN_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || {
      echo "--lan-ip must be the server's office-LAN interface IPv4 address." >&2
      exit 2
    }
    [[ "$SERVICE_PORT" =~ ^[0-9]+$ ]] && ((SERVICE_PORT >= 1 && SERVICE_PORT <= 65535)) || {
      echo "--port must be a valid TCP port." >&2
      exit 2
    }
    DOMAIN="$LAN_IP"
  elif [[ "$MODE" == "vpn" ]]; then
    VPN_IP="${VPN_IP:-$existing_vpn_ip}"
    SERVICE_PORT="${SERVICE_PORT:-${existing_vpn_port:-5000}}"
    [[ "$VPN_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || {
      echo "--vpn-ip must be the server's VPN interface IPv4 address." >&2
      exit 2
    }
    [[ "$SERVICE_PORT" =~ ^[0-9]+$ ]] && ((SERVICE_PORT >= 1 && SERVICE_PORT <= 65535)) || {
      echo "--port must be a valid TCP port." >&2
      exit 2
    }
    DOMAIN="$VPN_IP"
  else
    DOMAIN="${DOMAIN:-$existing_domain}"
    [[ -n "$DOMAIN" && "$DOMAIN" != "localhost" ]] || {
      echo "--domain is required for HTTPS mode." >&2
      exit 2
    }
  fi

  echo "==> Initializing configuration for $MODE mode"
  bash "$PROJECT_DIR/scripts/init-config.sh" --domain "$DOMAIN" --email "$EMAIL"
  set_env_value DEPLOYMENT_MODE "$MODE"
  set_env_value ARTIFACT_STORE "$ARTIFACT_STORE"
  if [[ "$MODE" == "lan" ]]; then
    set_env_value MLFLOW_LAN_IP "$LAN_IP"
    set_env_value MLFLOW_LAN_PORT "$SERVICE_PORT"
  elif [[ "$MODE" == "vpn" ]]; then
    set_env_value MLFLOW_VPN_IP "$VPN_IP"
    set_env_value MLFLOW_VPN_PORT "$SERVICE_PORT"
  fi
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
  )
  [[ "$ARTIFACT_STORE" == "minio" ]] && compose+=( -f "$PROJECT_DIR/compose.minio.yaml" )
  compose+=( -f "$PROJECT_DIR/compose.local.yaml" )

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

verify_vpn_binding() {
  local vpn_ip vpn_port container_id mapping
  vpn_ip="$(env_value_if_present MLFLOW_VPN_IP)"
  vpn_port="$(env_value_if_present MLFLOW_VPN_PORT)"
  vpn_port="${vpn_port:-5000}"
  compose=(
    docker compose
    --project-directory "$PROJECT_DIR"
    --env-file "$PROJECT_DIR/.env"
    -f "$PROJECT_DIR/compose.yaml"
  )
  [[ "$ARTIFACT_STORE" == "minio" ]] && compose+=( -f "$PROJECT_DIR/compose.minio.yaml" )
  compose+=( -f "$PROJECT_DIR/compose.vpn.yaml" )

  container_id="$("${compose[@]}" ps -q mlflow)"
  [[ -n "$container_id" ]] || {
    echo "MLflow container was not created." >&2
    exit 1
  }

  mapping="$(docker port "$container_id" 5000/tcp 2>/dev/null || true)"
  if [[ "$mapping" != "${vpn_ip}:${vpn_port}" ]]; then
    echo "Docker did not apply the required VPN port mapping." >&2
    echo "Expected: ${vpn_ip}:${vpn_port}" >&2
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
    "http://${vpn_ip}:${vpn_port}/health" >/dev/null

  echo
  echo "MLflow deployment completed successfully."
  echo "VPN endpoint: http://${vpn_ip}:${vpn_port}"
  echo "The service is bound only to the server VPN address."
  echo "Admin username: admin"
  echo "Admin password file: $PROJECT_DIR/secrets/mlflow_admin_password"
}

verify_lan_binding() {
  local lan_ip lan_port container_id mapping
  lan_ip="$(env_value_if_present MLFLOW_LAN_IP)"
  lan_port="$(env_value_if_present MLFLOW_LAN_PORT)"
  lan_port="${lan_port:-5000}"
  compose=(
    docker compose
    --project-directory "$PROJECT_DIR"
    --env-file "$PROJECT_DIR/.env"
    -f "$PROJECT_DIR/compose.yaml"
  )
  [[ "$ARTIFACT_STORE" == "minio" ]] && compose+=( -f "$PROJECT_DIR/compose.minio.yaml" )
  compose+=( -f "$PROJECT_DIR/compose.lan.yaml" )

  container_id="$("${compose[@]}" ps -q mlflow)"
  [[ -n "$container_id" ]] || {
    echo "MLflow container was not created." >&2
    exit 1
  }

  mapping="$(docker port "$container_id" 5000/tcp 2>/dev/null || true)"
  if [[ "$mapping" != "${lan_ip}:${lan_port}" ]]; then
    echo "Docker did not apply the required LAN port mapping." >&2
    echo "Expected: ${lan_ip}:${lan_port}" >&2
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
    "http://${lan_ip}:${lan_port}/health" >/dev/null

  echo
  echo "MLflow deployment completed successfully."
  echo "Office LAN endpoint: http://${lan_ip}:${lan_port}"
  echo "The service is bound only to the server LAN address."
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
elif [[ "$MODE" == "lan" ]]; then
  if ! bash "$PROJECT_DIR/scripts/deploy-lan.sh"; then
    echo "==> LAN deployment did not pass its final check; inspecting the effective port binding" >&2
    verify_lan_binding
    exit 0
  fi
  verify_lan_binding
elif [[ "$MODE" == "vpn" ]]; then
  if ! bash "$PROJECT_DIR/scripts/deploy-vpn.sh"; then
    echo "==> VPN deployment did not pass its final check; inspecting the effective port binding" >&2
    verify_vpn_binding
    exit 0
  fi
  verify_vpn_binding
else
  bash "$PROJECT_DIR/scripts/deploy.sh"
  echo "MLflow deployment completed successfully at https://${DOMAIN}"
fi
