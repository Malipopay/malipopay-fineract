#!/bin/bash
# Creates the two databases Fineract needs and the least-privilege role it connects as.
#
# Fineract uses two databases: a registry (fineract_tenants) that lists every tenant and
# holds its connection details, and one database per tenant that holds the actual financial
# data. Liquibase creates and migrates the schema inside both on first boot.
#
# This runs once, on an empty data volume. Changing it later has no effect on an existing
# database; see docs/malipopay/runbooks/backup-restore.md.
set -euo pipefail

: "${FINERACT_TENANTS_DB_NAME:?}"
: "${FINERACT_TENANT_DB_NAME:?}"
: "${FINERACT_DB_USER:?}"
: "${FINERACT_DB_PASSWORD:?}"

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname postgres <<-EOSQL
    -- The application role. It owns both databases, because Liquibase issues DDL on every
    -- boot, but it is not a superuser and cannot read or write anything else on the server.
    DO \$\$
    BEGIN
      IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = '${FINERACT_DB_USER}') THEN
        CREATE ROLE "${FINERACT_DB_USER}" LOGIN PASSWORD '${FINERACT_DB_PASSWORD}';
      END IF;
    END
    \$\$;

    CREATE DATABASE "${FINERACT_TENANTS_DB_NAME}" OWNER "${FINERACT_DB_USER}";
    CREATE DATABASE "${FINERACT_TENANT_DB_NAME}"  OWNER "${FINERACT_DB_USER}";

    REVOKE ALL ON DATABASE "${FINERACT_TENANTS_DB_NAME}" FROM PUBLIC;
    REVOKE ALL ON DATABASE "${FINERACT_TENANT_DB_NAME}"  FROM PUBLIC;
EOSQL

for db in "${FINERACT_TENANTS_DB_NAME}" "${FINERACT_TENANT_DB_NAME}"; do
  psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$db" <<-EOSQL
      CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
      ALTER SCHEMA public OWNER TO "${FINERACT_DB_USER}";
EOSQL
done

echo "init: created ${FINERACT_TENANTS_DB_NAME} and ${FINERACT_TENANT_DB_NAME} owned by ${FINERACT_DB_USER}"
