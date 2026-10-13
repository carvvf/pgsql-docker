#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=tools/lib/build_inputs.sh
source "${SCRIPT_DIR}/lib/build_inputs.sh"

resolve_build_inputs
docker build --platform linux/amd64 --pull --no-cache \
  --build-arg "PG_MAJOR=18" \
  --build-arg "GOSU_SOURCE_REF=${gosu_source_ref}" \
  --build-arg "GOSU_SOURCE_REVISION=${gosu_source_revision}" \
  --build-arg "ENTRYPOINT_SOURCE_COMMIT=${entrypoint_source_commit}" \
  --build-arg "POSTGRES_SOURCE_REF=${source_ref}" \
  --build-arg "POSTGRES_SOURCE_REVISION=${source_revision}" \
  --build-arg "POSTGRES_UPSTREAM_VERSION=${upstream_version}" \
  --build-arg "POSTGRES_UPSTREAM_DIGEST=${upstream_digest}" \
  --build-arg "POSTGRES_IMAGE_VERSION=${upstream_version}-local" \
  --build-arg "UBUNTU_BASE_IMAGE=${ubuntu_base_ref}" \
  --build-arg "UBUNTU_BASE_DIGEST=${ubuntu_base_digest}" \
  --build-arg "CACHEBUST=$(date -u +%s)" \
  -t "${IMAGE_REF:-pgsql-custom:local}" "${REPO_ROOT}"
