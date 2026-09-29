# MLflow + MinIO on an office LAN

This folder contains one deployment strategy only:

- MLflow over HTTP on a specific office-LAN IP
- the independent `../postgres` service for MLflow metadata
- MinIO for models and all other artifacts
- Docker Compose on a single Ubuntu server

MinIO and the shared PostgreSQL service are private Docker services. Only the
configured MLflow address is published to the LAN. PostgreSQL gives MLflow its
own database, login, and password, separate from Airflow.

## Install

Give the server a static LAN address, then run as the normal Linux user:

```bash
cd ~/washtym-infra/mlflow
bash main.sh --lan-ip 192.168.0.48 --port 5000
```

The first run installs Docker when necessary, starts the shared PostgreSQL
service, generates secrets, builds the pinned MLflow and MinIO images, creates
the private bucket, migrates only the MLflow database, and starts the services.
The MinIO image is built from its pinned
official source tag because upstream public container images are unavailable.

Open `http://192.168.0.48:5000` from a machine on the office network.

```bash
cat secrets/mlflow_admin_password
```

The username is `admin`. Keep the password and the entire `secrets/` directory
private.

For a fresh server where UFW should also be configured:

```bash
bash main.sh \
  --lan-ip 192.168.0.48 \
  --port 5000 \
  --configure-firewall \
  --lan-cidr 192.168.0.0/24 \
  --ssh-port 22
```

Confirm the CIDR and SSH port before using that command.

## Operations

```bash
bash scripts/status.sh
bash scripts/logs.sh
bash scripts/logs.sh mlflow
bash scripts/backup.sh
bash scripts/restore.sh --backup /absolute/backup/path --confirm-data-replacement
bash scripts/upgrade.sh 3.16.2
```

Backups are written beneath `backups/`. Copy them to encrypted off-server
storage; this server and its disk remain a single point of failure.

## Storage

- `shared_postgres_data`, database `mlflow`: runs, users, permissions, and registry metadata
- `mlflow_minio_data`: model files, datasets, plots, and other artifacts
- `backups/`: PostgreSQL dump, MinIO data snapshot, configuration, and secrets

## Destructive reset

```bash
bash reset-mlflow.sh
```

The script requires the confirmation phrase `DELETE-MLFLOW`. It removes MLflow
containers, MinIO artifacts, local images, configuration, and only the `mlflow`
database. It preserves the shared PostgreSQL service and volume and the Airflow
database. Backups are preserved unless `--purge-backups` is explicitly supplied.

## Files

- `main.sh`: complete installation and deployment
- `reset-mlflow.sh`: confirmed destructive reset
- `compose.yaml`: MLflow connected to shared PostgreSQL
- `compose.minio.yaml`: MinIO and S3 artifact configuration
- `compose.lan.yaml`: LAN-only port publication
- `scripts/status.sh`: health and artifact-destination check
- `scripts/logs.sh`: container logs
- `scripts/backup.sh`: consistent PostgreSQL and MinIO backup
- `scripts/restore.sh`: confirmed data restore
- `scripts/upgrade.sh`: backup, migration, and MLflow upgrade
- `scripts/bootstrap-ubuntu.sh`: Ubuntu/Docker bootstrap
