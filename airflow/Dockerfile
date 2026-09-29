ARG AIRFLOW_VERSION=3.3.2
FROM apache/airflow:${AIRFLOW_VERSION}

ARG AIRFLOW_VERSION

# Add pinned provider packages to requirements.txt when DAGs need them. Keeping
# the Airflow constraint explicit prevents a provider from upgrading core.
COPY --chown=airflow:root requirements.txt /opt/airflow/requirements.txt
RUN pip install --no-cache-dir \
      "apache-airflow==${AIRFLOW_VERSION}" \
      -r /opt/airflow/requirements.txt

USER root
COPY --chown=airflow:root docker/secure-entrypoint.sh /opt/airflow/bin/secure-entrypoint
RUN chmod 0555 /opt/airflow/bin/secure-entrypoint

USER airflow
ENTRYPOINT ["/usr/bin/dumb-init", "--", "/opt/airflow/bin/secure-entrypoint"]

