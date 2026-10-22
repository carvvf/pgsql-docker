#!/usr/bin/env bash
set -euo pipefail

# Exercises the image against the Ragtime `postgres` service contract in
# ../ragtime-rag-orch/docker/services/docker-compose.yml: same capability
# set, same read-only root filesystem, same POSTGRES_INITDB_ARGS, and the
# real Ragtime bootstrap init script mounted at /docker-entrypoint-initdb.d.

IMAGE_REF="${IMAGE_REF:-pgsql-custom:local}"
# Defaults to the vendored fixture (tests/fixtures/postgres-init), so this
# runs standalone in CI with no cross-repository checkout or secret. Set
# RAGTIME_REPO to a checked-out ragtime-rag-orch path, or to gh:<owner>/<repo>
# to download the scripts from that repository's master branch with the GitHub
# CLI, to instead run against the live contract and catch fixture drift
# locally. When a gh: download fails in an interactive terminal, the test asks
# for a local path instead, or for an empty answer to use the fixture.
RAGTIME_REPO="${RAGTIME_REPO:-}"
RAGTIME_GITHUB_BRANCH='master'
RAGTIME_INIT_PATH='docker/services/postgres-init'
RAGTIME_DOWNLOAD_DIR=''
INIT_DIR=''
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

# Downloads the top-level init scripts of a GitHub ragtime-rag-orch master
# commit, keeping each file's executable bit: docker-entrypoint.sh executes
# executable *.sh files and sources the others. Every failure returns non-zero
# so the caller can offer the local alternatives.
download_github_init_dir() {
  local repository="$1" destination="$2" commit directory_sha entries mode sha name
  if [[ ! "${repository}" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
    echo "Invalid GitHub source: gh:${repository}. Use gh:<owner>/<repo>." >&2
    return 1
  fi
  if ! command -v gh >/dev/null; then
    echo 'The GitHub CLI (gh) is not installed.' >&2
    return 1
  fi
  commit="$(gh api "repos/${repository}/commits/${RAGTIME_GITHUB_BRANCH}" --jq '.sha')" || return 1
  directory_sha="$(gh api "repos/${repository}/contents/${RAGTIME_INIT_PATH%/*}?ref=${commit}" \
    --jq ".[] | select(.type == \"dir\" and .name == \"${RAGTIME_INIT_PATH##*/}\") | .sha")" || return 1
  if [ -z "${directory_sha}" ]; then
    echo "${RAGTIME_INIT_PATH} not found in ${repository}@${commit}." >&2
    return 1
  fi
  entries="$(gh api "repos/${repository}/git/trees/${directory_sha}" \
    --jq '.tree[] | select(.type == "blob") | "\(.mode) \(.sha) \(.path)"')" || return 1
  while read -r mode sha name; do
    [ -n "${name}" ] || continue
    if [[ ! "${name}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || [[ ! "${mode}" =~ ^100(644|755)$ ]]; then
      echo "Skipping unsupported init entry: ${name} (mode ${mode})" >&2
      continue
    fi
    gh api -H 'Accept: application/vnd.github.raw+json' "repos/${repository}/git/blobs/${sha}" \
      >"${destination}/${name}" || return 1
    if [ "${mode}" = '100755' ]; then
      chmod 0755 "${destination}/${name}"
    else
      chmod 0644 "${destination}/${name}"
    fi
  done <<<"${entries}"
  echo "Using Ragtime bootstrap scripts from ${repository}@${commit} (${RAGTIME_GITHUB_BRANCH})." >&2
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ "${RAGTIME_REPO}" == gh:* ]]; then
  RAGTIME_DOWNLOAD_DIR="$(mktemp -d)"
  trap 'rm -rf "${RAGTIME_DOWNLOAD_DIR}"' EXIT
  # The container's postgres user must read the bind-mounted scripts.
  chmod 0755 "${RAGTIME_DOWNLOAD_DIR}"
  if download_github_init_dir "${RAGTIME_REPO#gh:}" "${RAGTIME_DOWNLOAD_DIR}"; then
    INIT_DIR="${RAGTIME_DOWNLOAD_DIR}"
  elif [ -t 0 ]; then
    find "${RAGTIME_DOWNLOAD_DIR}" -mindepth 1 -delete
    echo "Could not download the Ragtime bootstrap scripts from ${RAGTIME_REPO} (${RAGTIME_GITHUB_BRANCH})." >&2
    read -r -p 'Local ragtime-rag-orch path (empty uses the vendored fixture): ' RAGTIME_REPO
    RAGTIME_REPO="${RAGTIME_REPO/#\~/${HOME}}"
  else
    echo "Could not download the Ragtime bootstrap scripts from ${RAGTIME_REPO}; set RAGTIME_REPO to a local path or leave it empty for the vendored fixture." >&2
    exit 2
  fi
fi
if [ -z "${INIT_DIR}" ] && [ -n "${RAGTIME_REPO}" ]; then
  INIT_DIR="${RAGTIME_REPO}/${RAGTIME_INIT_PATH}"
elif [ -z "${INIT_DIR}" ]; then
  INIT_DIR="${SCRIPT_DIR}/fixtures/postgres-init"
  echo "Using the vendored Ragtime bootstrap fixture: ${INIT_DIR}" >&2
fi
if [ ! -d "${INIT_DIR}" ] || [ -z "$(ls -A "${INIT_DIR}")" ]; then
  echo "Bootstrap init directory not found or empty: ${INIT_DIR}" >&2
  echo "Set RAGTIME_REPO to a checked-out ragtime-rag-orch path or gh:<owner>/<repo>, or check tests/fixtures/postgres-init." >&2
  exit 2
fi

if ! docker image inspect "${IMAGE_REF}" >/dev/null 2>&1; then
  echo "Image not found: ${IMAGE_REF}. Run the local build task first." >&2
  exit 2
fi

EXPECTED_VERSION="$(docker image inspect "${IMAGE_REF}" --format '{{index .Config.Labels "io.github.carvvf.pgsql-docker.postgres.upstream.version"}}')"
if [[ ! "${EXPECTED_VERSION}" =~ ^18\.[0-9]+$ ]]; then
  echo "The image must record its verified PostgreSQL major 18 version. Rebuild it with tools/build_local_image.sh." >&2
  exit 1
fi

cleanup() {
  local exit_status=$?
  if [ "${exit_status}" -ne 0 ]; then
    echo "PostgreSQL container logs after test failure:" >&2
    docker logs --tail 200 "${CONTAINER_NAME}" >&2 || true
  fi
  docker rm -f "${CONTAINER_NAME}" >/dev/null 2>&1 || true
  docker volume rm "${DATA_VOLUME}" >/dev/null 2>&1 || true
  if [ -n "${RAGTIME_DOWNLOAD_DIR}" ]; then
    rm -rf "${RAGTIME_DOWNLOAD_DIR}"
  fi
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

SERVER_VERSION="$(docker exec "${CONTAINER_NAME}" gosu postgres psql -qtAX -d "${POSTGRES_DB}" -c 'show server_version')"
if [ "${SERVER_VERSION}" != "${EXPECTED_VERSION}" ]; then
  echo "PostgreSQL server version ${SERVER_VERSION} does not match image metadata ${EXPECTED_VERSION}." >&2
  exit 1
fi

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
