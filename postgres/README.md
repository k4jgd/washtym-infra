# Shared PostgreSQL

This private PostgreSQL instance serves MLflow and Airflow over the external
Docker network `localinfra_data`. It publishes no host port.

```bash
bash main.sh
bash scripts/status.sh
bash scripts/backup.sh
```

The applications use separate databases, roles, and passwords. Application
reset scripts may drop/recreate only their own database. They never delete the
shared `shared_postgres_data` volume or the other application's database.
