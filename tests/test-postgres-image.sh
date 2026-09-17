#!/usr/bin/env bash
set -euo pipefail

# Exercises the image against the Ragtime `postgres` service contract in
# ../ragtime-rag-orch/docker/services/docker-compose.yml: same capability
# set, same read-only root filesystem, same POSTGRES_INITDB_ARGS, and the
# real Ragtime bootstrap init script mounted at /docker-entrypoint-initdb.d.

IMAGE_REF="${IMAGE_REF:-pgsql-custom:local}"
# Defaults to the vendored fixture (tests/fixtures/postgres-init), so this
# runs standalone in CI with no cross-repository checkout or secret. Set
# RAGTIME_REPO to a checked-out ragtime-rag-orch path to instead run against
# the live contract and catch fixture drift locally.
RAGTIME_REPO="${RAGTIME_REPO:-}"
RUN_ID="${GITHUB_RUN_ID:-local}-$$"
CONTAINER_NAME="${CONTAINER_NAME:-postgres-image-test-${RUN_ID}}"
DATA_VOLUME="${DATA_VOLUME:-postgres-image-test-data-${RUN_ID}}"
POSTGRES_DB="${POSTGRES_DB:-ragtime}"
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-ci-bootstrap-password}"
RAGTIME_POSTGRES_OWNER="${RAGTIME_POSTGRES_OWNER:-ragtime_owner}"
RAGTIME_POSTGRES_OWNER_PASSWORD="${RAGTIME_POSTGRES_OWNER_PASSWORD:-ci-owner-password}"
RAGTIME_POSTGRES_APP_USER="${RAGTIME_POSTGRES_APP_USER:-ragtime_app}"
RAGTIME_POSTGRES_APP_PASSWORD="${RAGTIME_POSTGRES_APP_PASSWORD:-ci-app-password}"
POSTGRES_INITDB_ARGS="--locale-provider=builtin --builtin-locale=C.UTF-8 --lc-collate=C.UTF-8 --lc-ctype=C.UTF-8 --encoding=UTF8"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -n "${RAGTIME_REPO}" ]; then
  INIT_DIR="${RAGTIME_REPO}/docker/services/postgres-init"
else
  INIT_DIR="${SCRIPT_DIR}/fixtures/postgres-init"
fi
if [ ! -d "${INIT_DIR}" ]; then
  echo "Bootstrap init directory not found: ${INIT_DIR}" >&2
  echo "Set RAGTIME_REPO to a checked-out ragtime-rag-orch path, or check tests/fixtures/postgres-init." >&2
  exit 2
fi

if ! docker image inspect "${IMAGE_REF}" >/dev/null 2>&1; then
  echo "Image not found: ${IMAGE_REF}. Run the local build task first." >&2
  exit 2
fi

cleanup() {
  local exit_status=$?
  if [ "${exit_status}" -ne 0 ]; then
    echo "PostgreSQL container logs after test failure:" >&2
    docker logs --tail 200 "${CONTAINER_NAME}" >&2 || true
  fi
  docker rm -f "${CONTAINER_NAME}" >/dev/null 2>&1 || true
  docker volume rm "${DATA_VOLUME}" >/dev/null 2>&1 || true
  exit "${exit_status}"
}
trap cleanup EXIT

healthcheck() {
  # Matches Ragtime's Compose healthcheck exactly: querying as the socket's
  # own user via gosu, not `pg_isready`. See docker-compose.yml's comment on
  # why `pg_isready` is not used.
  docker exec "${CONTAINER_NAME}" \
    gosu postgres psql -qtAX -d "${POSTGRES_DB}" -c 'select 1' >/dev/null 2>&1
}

wait_for_healthy() {
  for _ in $(seq 1 60); do
    if healthcheck; then
      return 0
    fi
    sleep 1
  done
  echo "PostgreSQL did not become healthy in time." >&2
  return 1
}

docker volume create "${DATA_VOLUME}" >/dev/null

docker run -d \
  --name "${CONTAINER_NAME}" \
  --read-only \
  --cap-drop ALL \
  --cap-add CHOWN \
  --cap-add DAC_OVERRIDE \
  --cap-add FOWNER \
  --cap-add SETGID \
  --cap-add SETUID \
  --security-opt no-new-privileges:true \
  --memory 512m \
  --cpus 1.0 \
  --shm-size 256m \
  --tmpfs /tmp:rw,noexec,nosuid,nodev,size=64m \
  --tmpfs /var/run/postgresql:rw,noexec,nosuid,nodev,size=16m \
  -e POSTGRES_USER=postgres \
  -e "POSTGRES_PASSWORD=${POSTGRES_PASSWORD}" \
  -e "POSTGRES_DB=${POSTGRES_DB}" \
  -e "RAGTIME_POSTGRES_OWNER=${RAGTIME_POSTGRES_OWNER}" \
  -e "RAGTIME_POSTGRES_OWNER_PASSWORD=${RAGTIME_POSTGRES_OWNER_PASSWORD}" \
  -e "RAGTIME_POSTGRES_APP_USER=${RAGTIME_POSTGRES_APP_USER}" \
  -e "RAGTIME_POSTGRES_APP_PASSWORD=${RAGTIME_POSTGRES_APP_PASSWORD}" \
  -e "POSTGRES_INITDB_ARGS=${POSTGRES_INITDB_ARGS}" \
  --mount "type=volume,src=${DATA_VOLUME},dst=/var/lib/postgresql" \
  --mount "type=bind,src=$(cd "${INIT_DIR}" && pwd),dst=/docker-entrypoint-initdb.d,readonly" \
  "${IMAGE_REF}" \
  postgres \
  -c listen_addresses=* \
  -c idle_in_transaction_session_timeout=300000 \
  -c max_prepared_transactions=0 \
  -c wal_level=replica \
  -c password_encryption=scram-sha-256 \
  -c shared_preload_libraries=pg_stat_statements \
  -c TimeZone=GMT \
  -c statement_timeout=0 \
  >/dev/null

wait_for_healthy

# The Ragtime bootstrap script must have created the owner/app roles and the
# pg_stat_statements extension (see postgres-init/10-ragtime-bootstrap.sh).
docker exec "${CONTAINER_NAME}" \
  gosu postgres psql -qtAX -d "${POSTGRES_DB}" \
  -c "select count(*) from pg_roles where rolname in ('${RAGTIME_POSTGRES_OWNER}', '${RAGTIME_POSTGRES_APP_USER}')" \
  | grep -qx '2'

docker exec "${CONTAINER_NAME}" \
  gosu postgres psql -qtAX -d "${POSTGRES_DB}" \
  -c "select extname from pg_extension where extname = 'pg_stat_statements'" \
  | grep -qx 'pg_stat_statements'

docker exec "${CONTAINER_NAME}" \
  gosu postgres psql -qtAX -d "${POSTGRES_DB}" \
  -c "show shared_preload_libraries" \
  | grep -qx 'pg_stat_statements'

# Builtin locale provider, not glibc/ICU: this is the collation-drift
# mitigation the image must preserve (see AGENTS.md "Image and downstream
# compatibility contract").
docker exec "${CONTAINER_NAME}" \
  gosu postgres psql -qtAX -d "${POSTGRES_DB}" \
  -c "select datlocprovider from pg_database where datname = '${POSTGRES_DB}'" \
  | grep -qx 'b'

# Data written before a restart must survive it, using the same named volume
# Ragtime relies on.
docker exec "${CONTAINER_NAME}" \
  gosu postgres psql -qtAX -d "${POSTGRES_DB}" \
  -c "create table ci_smoke(id int primary key); insert into ci_smoke values (1);"

docker restart "${CONTAINER_NAME}" >/dev/null
wait_for_healthy

docker exec "${CONTAINER_NAME}" \
  gosu postgres psql -qtAX -d "${POSTGRES_DB}" \
  -c "select count(*) from ci_smoke" \
  | grep -qx '1'

echo "PostgreSQL image smoke test passed for ${IMAGE_REF}."
