# Airflow on the office LAN

This folder deploys Apache Airflow with the FAB Auth Manager and LocalExecutor.
It uses the independent PostgreSQL service in `../postgres`, with its own
`airflow` database and login. It does not share tables or credentials with
MLflow.

Only the Airflow API/UI port is published. PostgreSQL remains private on the
Docker network `localinfra_data`.

## Install

```bash
cd ~/washtym-infra/airflow
bash main.sh --lan-ip 192.168.0.48 --port 8080
```

`main.sh` installs Docker when necessary, starts the shared PostgreSQL service,
initializes only the Airflow database, builds the pinned Airflow image, creates
the first administrator, and starts the API server, scheduler, DAG processor,
and triggerer.

Open `http://192.168.0.48:8080` and sign in as `admin` using:

```bash
cat secrets/airflow_admin_password
```

## Operations

```bash
bash scripts/status.sh
bash scripts/logs.sh
bash scripts/check-dags.sh
bash scripts/airflow.sh dags list
bash scripts/backup.sh
bash scripts/restore.sh --backup /absolute/backup/path --confirm-data-replacement
bash scripts/upgrade.sh 3.3.3
```

Place version-controlled DAGs in `dags/`. Add pinned provider packages to
`requirements.txt`, rebuild, and run `scripts/check-dags.sh` after changes.

## Reset only Airflow

```bash
bash reset-airflow.sh
```

After the `DELETE-AIRFLOW` confirmation, the script removes Airflow containers,
logs, secrets, runtime state, and only the `airflow` database. It preserves the
shared PostgreSQL server and volume, the MLflow database, MLflow models, DAG
source, plugins, configuration, and backups.

## Capacity

LocalExecutor parallelism is limited to two. This is suitable for light
orchestration on the shared 8 GB host. Run heavy computation in external
systems rather than inside Airflow task processes.
