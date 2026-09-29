#!/usr/bin/env bash
set -Eeuo pipefail

read_secret() {
  local path="/run/secrets/$1"
  [[ -r "$path" ]] || { echo "Missing database secret: $path" >&2; exit 1; }
  tr -d '\r\n' < "$path"
}

validate_identifier() {
  [[ "$2" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] \
    || { echo "$1 contains an invalid PostgreSQL identifier: $2" >&2; exit 1; }
}

admin_user="${POSTGRES_USER:?POSTGRES_USER is required}"
admin_db="${POSTGRES_DB:?POSTGRES_DB is required}"

ensure_role_and_database() {
  local role="$1" database="$2" secret_name="$3" password
  validate_identifier role "$role"
  validate_identifier database "$database"
  password="$(read_secret "$secret_name")"
  [[ "$password" =~ ^[a-f0-9]{32,}$ ]] \
    || { echo "Unexpected password format in $secret_name" >&2; exit 1; }

  if [[ "$(psql -U "$admin_user" -d "$admin_db" -tAc "SELECT 1 FROM pg_roles WHERE rolname='$role'")" != "1" ]]; then
    psql -v ON_ERROR_STOP=1 -U "$admin_user" -d "$admin_db" \
      -c "CREATE ROLE \"$role\" LOGIN PASSWORD '$password'"
  else
    psql -v ON_ERROR_STOP=1 -U "$admin_user" -d "$admin_db" \
      -c "ALTER ROLE \"$role\" WITH LOGIN PASSWORD '$password'"
  fi

  if [[ "$(psql -U "$admin_user" -d "$admin_db" -tAc "SELECT 1 FROM pg_database WHERE datname='$database'")" != "1" ]]; then
    createdb -U "$admin_user" --owner="$role" "$database"
  fi
  psql -v ON_ERROR_STOP=1 -U "$admin_user" -d "$admin_db" \
    -c "ALTER DATABASE \"$database\" OWNER TO \"$role\""
  psql -v ON_ERROR_STOP=1 -U "$admin_user" -d "$admin_db" \
    -c "REVOKE CONNECT ON DATABASE \"$database\" FROM PUBLIC" \
    -c "GRANT CONNECT ON DATABASE \"$database\" TO \"$role\""
  psql -v ON_ERROR_STOP=1 -U "$admin_user" -d "$database" \
    -c "REVOKE ALL ON SCHEMA public FROM PUBLIC" \
    -c "GRANT ALL ON SCHEMA public TO \"$role\""
}

ensure_role_and_database "${MLFLOW_DB_USER:?}" "${MLFLOW_DB:?}" mlflow_db_password
ensure_role_and_database "${AIRFLOW_DB_USER:?}" "${AIRFLOW_DB:?}" airflow_db_password

echo "Shared PostgreSQL databases and roles are ready."
