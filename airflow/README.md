# Production-oriented Airflow on the shared Ubuntu server

This directory deploys Apache Airflow 3 with PostgreSQL, `LocalExecutor`, the
FAB Auth Manager, and the Airflow 3 API-server architecture. It shares the
Caddy HTTPS gateway from `../mlflow`, so only one service owns host ports 80
and 443.

It is hardened for a modest single-server installation, but it is not highly
available. A host failure stops orchestration. Keep encrypted backups elsewhere.

## Architecture

```text
Internet -> shared Caddy -> airflow-api-server
                              |
                 +------------+-------------+
                 |            |             |
             scheduler   DAG processor   triggerer
                 |            |             |
                 +---------- PostgreSQL ----+
```

`LocalExecutor` runs task processes inside the scheduler container. Redis and
Celery workers are intentionally omitted to reduce memory use on this 8 GB host.
Parallelism defaults to two tasks.

## Important capacity warning

Airflow officially recommends at least 4 GB for Airflow itself. This stack's
limits total approximately 4 GB. Together with the MLflow stack and Ubuntu,
the 8 GB server will have almost no safe capacity left for Flink. Treat this as
a small-workload deployment and monitor memory/OOM events. Running meaningful
Flink workloads on the same 8 GB host will require more RAM or another machine.

## Prerequisites and deployment order

1. Copy the whole `LocalInfra` directory to Ubuntu, preserving `mlflow` and
   `airflow` as sibling directories.
2. Bootstrap and deploy MLflow first. Its Caddy container becomes the shared
   gateway and creates the `localinfra_edge` Docker network.
3. Create a different DNS name for Airflow, such as `airflow.example.com`,
   pointing to the same server.
4. Keep only ports 80/443 public. Do not expose Airflow 8080 or PostgreSQL 5432.

If the host has not been bootstrapped yet:

```bash
sudo bash scripts/bootstrap-ubuntu.sh
```

This delegates to the shared Ubuntu bootstrap under `../mlflow`.

## Initialize configuration

```bash
bash scripts/init-config.sh --domain airflow.example.com
```

The script creates `.env`, five random secrets, persistent directories, and an
Airflow virtual-host file for the shared Caddy gateway. Review `.env` before
deployment. Runtime containers use your Linux UID with group `0`, matching the
permission model supported by the official Airflow image.

## Deploy

```bash
bash scripts/preflight.sh
bash scripts/deploy.sh
```

Deployment builds the pinned image, initializes PostgreSQL, migrates the Airflow
schema, creates the first FAB administrator, starts all Airflow components,
reloads Caddy, and verifies the public health endpoint.

Open `https://YOUR_AIRFLOW_DOMAIN`. Login with username `admin`; obtain the
initial password with:

```bash
sed -n '1p' secrets/airflow_admin_password
```

Change that password after the first login and create named users with the
minimum suitable FAB roles. The secret file retains only the original bootstrap
password after rotation.

## DAGs and dependencies

Store DAG source files under `dags/` and keep them in version control. Runtime
containers mount that directory read-only. Tasks can use the container's
size-limited `/tmp`; workflows that create substantial local files need an
explicit data volume or, preferably, external object storage.

Add only pinned Python providers or libraries to `requirements.txt`, then run:

```bash
docker compose --env-file .env build --pull
bash scripts/deploy.sh
```

Test DAG parsing after every change:

```bash
bash scripts/check-dags.sh
```

Avoid network calls and expensive database queries at module-import time in DAG
files; the dedicated DAG processor imports them repeatedly.

## Routine operations

```bash
bash scripts/status.sh
bash scripts/logs.sh
bash scripts/logs.sh airflow-scheduler
bash scripts/check-dags.sh
bash scripts/airflow.sh dags list
bash scripts/backup.sh
bash scripts/upgrade.sh 3.3.3
bash scripts/uninstall.sh
```

Create another FAB user through the CLI if desired:

```bash
bash scripts/airflow.sh users create \
  --username operator \
  --firstname Data \
  --lastname Operator \
  --role User \
  --email operator@example.com
```

The command securely prompts for a password.

## Backups

`backup.sh` saves:

- PostgreSQL metadata, users, connections, variables, and task state
- DAG source
- Local task logs
- Configuration and plugins
- The Fernet/JWT/API secrets required to decrypt and operate a restored system
- The shared Caddy site configuration

Backups under `backups/` contain credentials. Copy them to encrypted off-server
storage and regularly test restoration.

Example nightly cron entry:

```cron
30 2 * * * /usr/bin/bash /absolute/path/to/airflow/scripts/backup.sh >> /var/log/airflow-backup.log 2>&1
```

Restore metadata and logs with:

```bash
bash scripts/restore.sh \
  --backup /absolute/path/to/airflow/backups/20260929T120000Z \
  --confirm-data-replacement
```

Configuration, DAGs, plugins, and encryption secrets are not overwritten
automatically during restore; inspect `configuration.tar.gz` and `dags.tar.gz`
and restore them deliberately when rebuilding a lost host.

## Upgrades

Read Airflow release notes and provider compatibility information first.
`upgrade.sh` creates a backup, stops Airflow writers, builds the requested
version, applies `airflow db migrate`, and starts health-checked services.
Database migrations may complicate rollback; retain the pre-upgrade backup.

## Security and operations

- FAB Auth Manager is used because Airflow's Simple Auth Manager is explicitly
  intended only for development/testing.
- PostgreSQL and Airflow port 8080 are never published to the host.
- Secrets are injected from local files and exported only inside containers.
- DAG/config/plugin mounts are read-only at runtime.
- Containers drop Linux capabilities and use `no-new-privileges`.
- API changes to DAG state require confirmation.
- Authentication rate limiting and database-backed sessions are enabled.
- Only scheduler and triggerer join the egress-enabled network because task and
  trigger code may need external services.

Monitor container health, scheduler heartbeat, DAG import errors, database size,
task failures/retries, disk usage, memory pressure, and backup success. Local
task logs need retention or remote logging as their volume grows.
