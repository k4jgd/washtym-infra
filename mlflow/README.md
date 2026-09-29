# Production MLflow on one Ubuntu server

This directory deploys a small-team MLflow tracking and model-registry service
using Docker Compose, PostgreSQL, local persistent artifact storage, built-in
MLflow authentication, and Caddy-managed HTTPS.

It is production-hardened for a single server, but it is not highly available.
The host remains a single point of failure. Keep encrypted backups off the host.

## Architecture

```text
Clients -> HTTPS :443 -> Caddy -> MLflow :5000 -> PostgreSQL :5432
                                  |
                                  `-> mlflow_artifacts Docker volume
```

Only Caddy publishes host ports. PostgreSQL and MLflow use private Docker
networks and cannot be reached directly from outside Docker. Caddy also joins
the external `localinfra_edge` Docker network so it can be the shared HTTPS
gateway for Airflow and later services on this same host.

## Prerequisites

- Fresh Ubuntu 22.04 or 24.04 server
- A DNS name whose A/AAAA record points to the server
- Inbound TCP 80 and 443; inbound UDP 443 is optional for HTTP/3
- A user with sudo access
- Encrypted off-server storage for backups

MLflow here is the tracking/registry service. Do not run training jobs or
production inference inside this stack.

## 1. Install host dependencies

From this directory on the server:

```bash
sudo bash scripts/bootstrap-ubuntu.sh
```

The firewall is deliberately unchanged by default. After confirming the SSH
port, it can be configured explicitly:

```bash
sudo bash scripts/bootstrap-ubuntu.sh --configure-firewall --ssh-port 22
```

Log out and back in if the script added your user to the `docker` group.
Membership in that group is effectively root access; grant it only to trusted
administrators.

## 2. Point DNS to the server

Create the DNS record before deployment. Caddy must be reachable on ports 80
and 443 to obtain a public TLS certificate.

## 3. Initialize configuration and secrets

```bash
bash scripts/init-config.sh \
  --domain mlflow.example.com \
  --email admin@example.com
```

Review `.env`. The script creates random values under `secrets/`; neither file
is tracked by Git. The secrets directory is owner-only. Its files are readable
inside the unprivileged containers through Compose's file-backed secret mounts.

Run the preflight independently if desired:

```bash
bash scripts/preflight.sh
```

It validates Linux, Docker access, Compose syntax, DNS, ports, and reports the
detected CPU, memory, and free disk capacity. Deployment runs it automatically.

## 4. Deploy

```bash
bash scripts/deploy.sh
```

The deployment validates configuration, pulls pinned images, builds the MLflow
image, starts PostgreSQL, applies schema migrations, starts HTTPS, and checks
the public health endpoint. It also removes the admin bootstrap password from
subsequent MLflow container environments.

Login at `https://YOUR_DOMAIN` using username `admin`. The initial password is:

```bash
sed -n '1p' secrets/mlflow_admin_password
```

Create named user accounts, assign only required permissions, and rotate the
initial administrator password after first login.

## No-DNS deployment using an SSH tunnel

If no DNS name is available, do not expose MLflow over public HTTP. Initialize
with `localhost`, then use the local-only deployment mode:

```bash
bash main.sh --email admin@example.com
```

On later runs, `bash main.sh` reuses the existing configuration. The script
bootstraps Docker when necessary, initializes secrets, deploys the services,
checks the actual loopback port mapping, checks health, and prints the tunnel
command. If Docker group membership was added during the run, reconnect once
and run the same command again.

This publishes MLflow only on the server's loopback interface. It cannot be
reached directly from the network. On an administrator workstation, create an
SSH tunnel and keep that terminal open:

```bash
ssh -N -L 5000:127.0.0.1:5000 USER@SERVER_IP
```

Open `http://localhost:5000` locally. The HTTP connection exists only inside
the encrypted SSH tunnel. Configure MLflow clients on that workstation with
`MLFLOW_TRACKING_URI=http://localhost:5000` while the tunnel is active.

Use `bash scripts/status-local.sh` for health checks in this mode. Obtain a
real DNS name and redeploy with `scripts/deploy.sh` before offering MLflow as a
directly accessible shared Internet service.

## VPN-only deployment by IP address

To let trusted VPN clients access MLflow directly without an SSH tunnel, bind
the published port to the IPv4 address assigned to the server's VPN interface:

```bash
bash main.sh \
  --mode vpn \
  --vpn-ip 100.64.0.10 \
  --port 5000 \
  --email admin@example.com
```

Replace the example address with the server's actual VPN address. The preflight
check refuses to deploy unless that address is currently assigned to a local
interface. After the first run, `bash main.sh` reuses the saved VPN mode,
address, and port. VPN-connected clients open `http://100.64.0.10:5000`.

This mode does not publish MLflow on the server's public or LAN addresses.
PostgreSQL remains on the internal Docker network and is never published. Use
`bash scripts/status-vpn.sh` for VPN-mode health checks. HTTP is acceptable here
only when the VPN itself provides trusted, encrypted transport; do not expose
the configured port through a public cloud firewall or router.

## Office-LAN HTTP deployment by IP address

For a trusted, isolated office network, bind MLflow only to the server's static
LAN address:

```bash
bash setup-lan.sh \
  --lan-ip 192.168.1.50 \
  --port 5000 \
  --email admin@example.com
```

The preflight check requires the IP to be assigned to a server interface. Users
on the office network open `http://192.168.1.50:5000`. PostgreSQL remains on the
internal Docker network. Do not forward this port from an Internet router or
allow it through a public-facing firewall. Basic Auth credentials are not
encrypted by HTTP, so use this mode only on a trusted network.

Check this deployment with `bash scripts/status-lan.sh`. Later runs can use
`bash setup-lan.sh` because the LAN mode, address, and port are saved in `.env`.

## Complete reset

To permanently remove the MLflow containers, database, artifacts, generated
image, MLflow-only networks, configuration, secrets, and runtime state:

```bash
bash reset-mlflow.sh
```

The script lists exact targets and requires the typed phrase `DELETE-MLFLOW`.
Backups are preserved by default. To delete backups too, use
`bash reset-mlflow.sh --purge-backups`; this requires the longer confirmation
phrase `DELETE-MLFLOW-INCLUDING-BACKUPS`. The shared `localinfra_edge` network,
Docker itself, and files belonging to Airflow are never removed.

## MinIO artifact storage

To store model files and all other MLflow artifacts in a private MinIO bucket,
start from a reset deployment and run:

```bash
bash setup-minio.sh \
  --mode lan \
  --lan-ip 192.168.1.50 \
  --port 5000 \
  --email admin@example.com
```

MinIO is reachable only by containers on the internal backend network; neither
its S3 API nor console is published on the host. MLflow proxies uploads and
downloads, so client machines need only the MLflow URL and MLflow credentials.
PostgreSQL continues to hold run and registry metadata. Model files, plots, and
other artifacts are stored in the `mlflow_minio_data` volume under the private
`mlflow-artifacts` bucket.

`setup-minio.sh` refuses to switch an existing local-artifact deployment unless
`--confirm-switch` is supplied because it does not migrate old artifact files.
The safer path is to back up, reset, and deploy MinIO from the beginning.
`scripts/backup.sh` automatically detects MinIO, briefly stops artifact writers,
and includes a consistent copy of the MinIO data volume.

Configure a client with an individual MLflow account:

```bash
export MLFLOW_TRACKING_URI=http://192.168.1.50:5000
export MLFLOW_TRACKING_USERNAME=your-user
export MLFLOW_TRACKING_PASSWORD='your-password'
```

Avoid placing the password directly in shell history or checked-in project
files; use the secret facility provided by the client machine or CI system.

## Routine operations

```bash
bash scripts/status.sh             # container, health, and version checks
bash scripts/preflight.sh          # repeat host/configuration checks
bash scripts/logs.sh               # follow every service log
bash scripts/logs.sh mlflow        # follow only MLflow logs
bash scripts/backup.sh             # database, artifacts, config, and secrets
bash scripts/upgrade.sh 3.16.2     # backup, migrate, and upgrade
bash scripts/uninstall.sh          # stop/remove containers; keep all data
```

Backups are stored in `backups/<UTC timestamp>/`. They contain credentials and
must be copied to encrypted off-server storage. Local retention is controlled
by `BACKUP_RETENTION_DAYS` in `.env`.

Example cron entry for a nightly backup at 02:15:

```cron
15 2 * * * /usr/bin/bash /absolute/path/to/mlflow/scripts/backup.sh >> /var/log/mlflow-backup.log 2>&1
```

Ensure the cron user has Docker access and protect the log from untrusted users.

## Restore

Restoration replaces the current database and artifact volume. The script
requires both a command-line acknowledgement and an interactive typed phrase:

```bash
bash scripts/restore.sh \
  --backup /absolute/path/to/mlflow/backups/20260928T120000Z \
  --confirm-data-replacement
```

The configuration archive is not automatically restored because overwriting
live secrets and deployment files should be a deliberate recovery decision.

## Upgrade policy

Read MLflow release notes first. `upgrade.sh` makes a backup, changes only the
pinned MLflow version, builds the image, and applies database migrations while
MLflow is stopped. Database migrations may not be reversible. A rollback after
a migration can require restoring both the database and artifacts from the
pre-upgrade backup.

Client SDKs should normally match the server version. Upgrade the server before
clients that require newer APIs.

## Monitoring recommendations

Monitor at least:

- `https://YOUR_DOMAIN/health`
- container restart counts and unhealthy status
- disk space and inode utilization
- memory pressure and OOM events
- PostgreSQL and backup success
- HTTPS certificate expiry
- reverse-proxy 4xx/5xx rates

Alert before disk usage reaches 80 percent. Local artifacts, PostgreSQL data,
container images, logs, and backups all compete for the same host disk.

## Data locations

Docker manages the persistent volumes:

- `mlflow_postgres_data`
- `mlflow_artifacts`
- `mlflow_minio_data` when MinIO artifact storage is enabled
- `mlflow_caddy_data`
- `mlflow_caddy_config`

`bash scripts/uninstall.sh` preserves them. The explicit `--purge-data` option
requires confirmation and permanently removes them. Backups are not deleted.

## Moving artifacts to object storage

The default local artifact volume is appropriate for a modest single-node
installation. For higher durability, change `MLFLOW_ARTIFACTS_DESTINATION` in
`compose.yaml` to an S3-compatible URI and provide credentials through secrets
or an instance identity. Do this before creating production experiments:
artifact locations are recorded when each experiment is created, and old
experiments are not automatically migrated.
