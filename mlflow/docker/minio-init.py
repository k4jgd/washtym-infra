#!/usr/bin/env python3
import os
import re
import time
from pathlib import Path

import boto3
from botocore.config import Config
from botocore.exceptions import ClientError, EndpointConnectionError


def read_secret(name: str) -> str:
    path = Path("/run/secrets") / name
    try:
        value = path.read_text(encoding="utf-8").strip()
    except OSError as exc:
        raise SystemExit(f"Required secret is missing or unreadable: {path}: {exc}")
    if not value:
        raise SystemExit(f"Required secret is empty: {path}")
    return value


bucket = os.environ.get("MINIO_BUCKET", "")
if not re.fullmatch(r"[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]", bucket):
    raise SystemExit(
        "MINIO_BUCKET must be 3-63 characters and contain only lowercase "
        "letters, numbers, dots, and hyphens."
    )

client = boto3.client(
    "s3",
    endpoint_url="http://minio:9000",
    aws_access_key_id=read_secret("minio_access_key"),
    aws_secret_access_key=read_secret("minio_secret_key"),
    region_name="us-east-1",
    config=Config(
        signature_version="s3v4",
        s3={"addressing_style": "path"},
        retries={"max_attempts": 5},
    ),
)

for attempt in range(1, 31):
    try:
        client.head_bucket(Bucket=bucket)
        break
    except EndpointConnectionError:
        if attempt == 30:
            raise
        time.sleep(2)
    except ClientError as exc:
        code = str(exc.response.get("Error", {}).get("Code", ""))
        if code in {"404", "NoSuchBucket", "NotFound"}:
            client.create_bucket(Bucket=bucket)
            break
        raise

# A bucket has no public access by default. Remove any policy left by a prior
# partial deployment so all artifact access remains behind authenticated MLflow.
try:
    client.delete_bucket_policy(Bucket=bucket)
except ClientError as exc:
    code = str(exc.response.get("Error", {}).get("Code", ""))
    if code not in {"NoSuchBucketPolicy", "NoSuchPolicy", "404"}:
        raise

print(f"MinIO bucket is ready and private: {bucket}")
