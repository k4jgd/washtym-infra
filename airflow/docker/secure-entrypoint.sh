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

AIRFLOW__DATABASE__SQL_ALCHEMY_CONN="postgresql+psycopg://${POSTGRES_USER}:${encoded_password}@${POSTGRES_HOST}:${POSTGRES_PORT}/${POSTGRES_DB}"
AIRFLOW__CORE__FERNET_KEY="$(read_secret airflow_fernet_key)"
AIRFLOW__API_AUTH__JWT_SECRET="$(read_secret airflow_jwt_secret)"
AIRFLOW__API__SECRET_KEY="$(read_secret airflow_api_secret)"
export AIRFLOW__DATABASE__SQL_ALCHEMY_CONN AIRFLOW__CORE__FERNET_KEY
export AIRFLOW__API_AUTH__JWT_SECRET AIRFLOW__API__SECRET_KEY

if [[ "${AIRFLOW_BOOTSTRAP_ADMIN:-false}" == "true" ]]; then
  _AIRFLOW_WWW_USER_PASSWORD="$(read_secret airflow_admin_password)"
  export _AIRFLOW_WWW_USER_PASSWORD
fi

exec /entrypoint "$@"
