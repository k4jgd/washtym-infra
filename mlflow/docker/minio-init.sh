#!/bin/sh
set -eu

read_secret() {
  path="/run/secrets/$1"
  if [ ! -r "$path" ]; then
    echo "Required secret is missing or unreadable: $path" >&2
    exit 1
  fi
  tr -d '\r\n' < "$path"
}

case "${MINIO_BUCKET:-}" in
  ""|*[!a-z0-9.-]*)
    echo "MINIO_BUCKET must contain only lowercase letters, numbers, dots, and hyphens." >&2
    exit 1
    ;;
esac

access_key="$(read_secret minio_access_key)"
secret_key="$(read_secret minio_secret_key)"

mc alias set local http://minio:9000 "$access_key" "$secret_key"
mc mb --ignore-existing "local/${MINIO_BUCKET}"
mc anonymous set none "local/${MINIO_BUCKET}"

echo "MinIO bucket is ready: ${MINIO_BUCKET}"

