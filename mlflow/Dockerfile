ARG MLFLOW_VERSION=3.16.1
FROM ghcr.io/mlflow/mlflow:v${MLFLOW_VERSION}

ARG MLFLOW_VERSION
ARG MLFLOW_UID=1000
ARG MLFLOW_GID=1000

USER root

# The official image contains MLflow. Add only server-side dependencies needed
# by PostgreSQL and built-in authentication, pinned for repeatable builds.
RUN python -m pip install --no-cache-dir \
      "mlflow[auth]==${MLFLOW_VERSION}" \
      "boto3==1.43.97" \
      "psycopg2-binary==2.9.10" \
    && groupadd --gid "${MLFLOW_GID}" mlflow-runtime \
    && useradd --uid "${MLFLOW_UID}" --gid "${MLFLOW_GID}" \
         --create-home --shell /usr/sbin/nologin mlflow-runtime \
    && mkdir -p /mlartifacts \
    && chown -R mlflow-runtime:mlflow-runtime /mlartifacts

COPY --chown=mlflow-runtime:mlflow-runtime docker/mlflow-entrypoint.sh /usr/local/bin/mlflow-entrypoint
RUN chmod 0555 /usr/local/bin/mlflow-entrypoint

USER mlflow-runtime:mlflow-runtime
ENV HOME=/tmp
ENTRYPOINT ["/usr/local/bin/mlflow-entrypoint"]
CMD ["mlflow", "server", "--app-name", "basic-auth", "--serve-artifacts"]
