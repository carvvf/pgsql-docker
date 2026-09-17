#!/usr/bin/env bash
# Vendored test fixture, copied verbatim from
# ../ragtime-rag-orch/docker/services/postgres-init/10-ragtime-bootstrap.sh
# so that CI can validate the real Ragtime bootstrap contract without a
# cross-repository checkout or secret. This is a point-in-time copy: if the
# real script changes, this fixture must be updated to match, or the CI test
# stops reflecting the actual downstream contract. See AGENTS.md "Image and
# downstream compatibility contract".
set -euo pipefail

: "${POSTGRES_DB:?POSTGRES_DB must be set.}"
: "${RAGTIME_POSTGRES_OWNER:?RAGTIME_POSTGRES_OWNER must be set.}"
: "${RAGTIME_POSTGRES_OWNER_PASSWORD:?RAGTIME_POSTGRES_OWNER_PASSWORD must be set.}"
: "${RAGTIME_POSTGRES_APP_USER:?RAGTIME_POSTGRES_APP_USER must be set.}"
: "${RAGTIME_POSTGRES_APP_PASSWORD:?RAGTIME_POSTGRES_APP_PASSWORD must be set.}"

bootstrap_user="${POSTGRES_USER:-postgres}"
if [[ "${RAGTIME_POSTGRES_OWNER}" == "${bootstrap_user}" \
    || "${RAGTIME_POSTGRES_APP_USER}" == "${bootstrap_user}" \
    || "${RAGTIME_POSTGRES_APP_USER}" == "${RAGTIME_POSTGRES_OWNER}" ]]; then
    echo "PostgreSQL bootstrap, owner, and application roles must be distinct." >&2
    exit 64
fi

psql \
    --set=ON_ERROR_STOP=1 \
    --username "${bootstrap_user}" \
    --dbname postgres \
    --set=database_name="${POSTGRES_DB}" \
    --set=owner_name="${RAGTIME_POSTGRES_OWNER}" \
    --set=owner_password="${RAGTIME_POSTGRES_OWNER_PASSWORD}" \
    --set=app_name="${RAGTIME_POSTGRES_APP_USER}" \
    --set=app_password="${RAGTIME_POSTGRES_APP_PASSWORD}" <<'SQL'
SELECT format(
    'CREATE ROLE %I LOGIN CREATEROLE CREATEDB BYPASSRLS PASSWORD %L',
    :'owner_name',
    :'owner_password'
)
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'owner_name')
\gexec

SELECT format(
    'CREATE ROLE %I LOGIN NOCREATEROLE NOCREATEDB NOBYPASSRLS PASSWORD %L',
    :'app_name',
    :'app_password'
)
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'app_name')
\gexec

-- The owner administers the application role: it pins that role's search_path
-- when it creates the schema. A CREATEROLE role may only alter roles it holds
-- ADMIN OPTION on, and it holds that only for roles it created itself -- these
-- two were both created here, by the bootstrap superuser.
SELECT format('GRANT %I TO %I WITH ADMIN OPTION', :'app_name', :'owner_name')
\gexec

SELECT format('CREATE DATABASE %I OWNER %I', :'database_name', :'owner_name')
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = :'database_name')
\gexec
SELECT format('ALTER DATABASE %I OWNER TO %I', :'database_name', :'owner_name')
\gexec

SELECT format('REVOKE ALL ON DATABASE %I FROM PUBLIC', :'database_name')
\gexec
SELECT format('GRANT ALL ON DATABASE %I TO %I', :'database_name', :'owner_name')
\gexec
SELECT format('GRANT CONNECT ON DATABASE %I TO %I', :'database_name', :'app_name')
\gexec
SQL

psql \
    --set=ON_ERROR_STOP=1 \
    --username "${bootstrap_user}" \
    --dbname "${POSTGRES_DB}" \
    --command "CREATE EXTENSION IF NOT EXISTS pg_stat_statements;"
