# WashTym local infrastructure

Single-server office-LAN deployment:

```text
postgres/  one private PostgreSQL server
           ├── mlflow database + mlflow role
           └── airflow database + airflow role

mlflow/    http://SERVER_LAN_IP:5000, with models in private MinIO
airflow/   http://SERVER_LAN_IP:8080, using LocalExecutor
```

PostgreSQL publishes no host port. Applications reach it only through the
internal Docker network `localinfra_data`.

## Fresh-server deployment

Run MLflow first; its entry point installs Docker when needed and automatically
initializes the shared PostgreSQL stack:

```bash
cd ~/washtym-infra/mlflow
bash main.sh --lan-ip 192.168.0.48 --port 5000
```

If Docker group membership was added, reconnect through SSH and repeat that
command. Then deploy Airflow:

```bash
cd ~/washtym-infra/airflow
bash main.sh --lan-ip 192.168.0.48 --port 8080
```

Check all three stacks:

```bash
cd ~/washtym-infra/postgres && bash scripts/status.sh
cd ~/washtym-infra/mlflow && bash scripts/status.sh
cd ~/washtym-infra/airflow && bash scripts/status.sh
```

To replace all LocalInfra containers without deleting any volumes or application
data, run from the repository root:

```bash
bash dummy.sh --lan-ip 192.168.0.48
```

The script displays the exact targeted containers, requires the confirmation
phrase `REDEPLOY-LOCALINFRA`, removes only the three LocalInfra Compose projects,
and starts PostgreSQL, MLflow, and Airflow in dependency order.

## Reset isolation

`mlflow/reset-mlflow.sh` recreates only the `mlflow` database and removes
MLflow/MinIO state. `airflow/reset-airflow.sh` recreates only the `airflow`
database and removes Airflow runtime state. Neither script deletes the shared
PostgreSQL service, `shared_postgres_data` volume, database role passwords, or
the other application's database.

## Existing deployments

This layout changes database ownership. Before replacing an existing deployed
folder, run that deployment's backup script and copy the backup off-server.
Application database dumps can then be restored into the matching database in
the shared PostgreSQL service. Do not delete an old PostgreSQL volume until the
new deployment and restored data have been verified.
