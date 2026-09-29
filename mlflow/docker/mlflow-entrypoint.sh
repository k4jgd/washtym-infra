#!/usr/bin/env bash
set -Eeuo pipefail

read_secret() {
  local path="/run/secrets/$1"
  if [[ ! -r "$path" ]]; then
    echo "Required secret is missing or unreadable: $path" >&2
    exit 1
  fi
  tr -d '\r\n' < "$path"
}

for name in POSTGRES_HOST POSTGRES_PORT POSTGRES_DB POSTGRES_USER; do
  if [[ -z "${!name:-}" ]]; then
    echo "Required environment variable is empty: $name" >&2
    exit 1
  fi
done

if [[ ! "$POSTGRES_DB" =~ ^[A-Za-z0-9_]+$ ]] || \
   [[ ! "$POSTGRES_USER" =~ ^[A-Za-z0-9_]+$ ]]; then
  echo "POSTGRES_DB and POSTGRES_USER may contain only letters, numbers, and underscores." >&2
  exit 1
fi

postgres_password="$(read_secret postgres_password)"
encoded_password="$(POSTGRES_PASSWORD="$postgres_password" python - <<'PY'
import os
from urllib.parse import quote

print(quote(os.environ["POSTGRES_PASSWORD"], safe=""))
PY
)"
unset postgres_password

export MLFLOW_BACKEND_STORE_URI="postgresql+psycopg2://${POSTGRES_USER}:${encoded_password}@${POSTGRES_HOST}:${POSTGRES_PORT}/${POSTGRES_DB}"
MLFLOW_FLASK_SERVER_SECRET_KEY="$(read_secret mlflow_flask_secret)"
export MLFLOW_FLASK_SERVER_SECRET_KEY
export MLFLOW_AUTH_CONFIG_PATH=/tmp/mlflow-auth.ini

# MLflow requires the bootstrap password only while creating the first admin.
# deploy.sh writes this marker after the authenticated database is initialized.
if [[ ! -f /run/mlflow-runtime/auth-bootstrap-complete ]]; then
  MLFLOW_AUTH_ADMIN_PASSWORD="$(read_secret mlflow_admin_password)"
  export MLFLOW_AUTH_ADMIN_PASSWORD
else
  unset MLFLOW_AUTH_ADMIN_PASSWORD || true
fi

umask 077
printf '[mlflow]\ndatabase_uri = %s\ndefault_permission = NO_PERMISSIONS\n' \
  "$MLFLOW_BACKEND_STORE_URI" > "$MLFLOW_AUTH_CONFIG_PATH"
printf 'authorization_function = mlflow.server.auth:authenticate_request_basic_auth\n' \
  >> "$MLFLOW_AUTH_CONFIG_PATH"

exec "$@"
