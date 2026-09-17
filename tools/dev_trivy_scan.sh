#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

TRIVY_IMAGE="${TRIVY_IMAGE:-aquasec/trivy:0.74.0}"
IMAGE_REF="${IMAGE_REF:-pgsql-custom:local}"
REPORT_SEVERITIES="${REPORT_SEVERITIES:-UNKNOWN,LOW,MEDIUM,HIGH,CRITICAL}"
FAIL_SEVERITIES="${FAIL_SEVERITIES:-HIGH,CRITICAL}"
REPORTS_DIR="${REPORTS_DIR:-${REPO_ROOT}/reports/trivy}"
TRIVY_CACHE_DIR="${TRIVY_CACHE_DIR:-${REPORTS_DIR}/cache}"
HOST_UID="$(id -u)"
HOST_GID="$(id -g)"

if ! command -v docker >/dev/null 2>&1; then
  echo 'Docker is required for the pinned local Trivy scanner.' >&2
  exit 127
fi
if ! docker info >/dev/null 2>&1; then
  echo 'The Docker daemon is not reachable.' >&2
  exit 127
fi
DOCKER_SOCKET_GID="$(stat -c '%g' /var/run/docker.sock)"
if ! docker image inspect "${IMAGE_REF}" >/dev/null 2>&1; then
  echo "Image not found: ${IMAGE_REF}. Run the local build task first." >&2
  exit 2
fi

mkdir -p "${REPORTS_DIR}" "${TRIVY_CACHE_DIR}"
timestamp="$(date -u +%Y%m%d-%H%M%S)"
overall_status=0

run_trivy() {
  docker run --rm \
    --user "${HOST_UID}:${HOST_GID}" \
    --group-add "${DOCKER_SOCKET_GID}" \
    -e TRIVY_CACHE_DIR=/trivy-cache \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v "${REPO_ROOT}:/workspace:ro" \
    -v "${REPORTS_DIR}:/reports" \
    -v "${TRIVY_CACHE_DIR}:/trivy-cache" \
    -w /workspace \
    "${TRIVY_IMAGE}" "$@"
}

merge_status() {
  local candidate="$1"
  if (( candidate > overall_status )); then
    overall_status="${candidate}"
  fi
}

scan_target() {
  local name="$1"
  local mode="$2"
  local target="$3"
  shift 3
  local extra_args=("$@")
  local json_report="/reports/${timestamp}.${name}.json"
  local scan_status=0

  echo "[Trivy] Report scan: ${name}" >&2
  run_trivy "${mode}" --severity "${REPORT_SEVERITIES}" "${extra_args[@]}" "${target}" \
    | tee "${REPORTS_DIR}/${timestamp}.${name}.txt"
  run_trivy "${mode}" --severity "${REPORT_SEVERITIES}" \
    --format json --output "${json_report}" "${extra_args[@]}" "${target}"

  set +e
  run_trivy "${mode}" --severity "${FAIL_SEVERITIES}" \
    --exit-code 1 --quiet "${extra_args[@]}" "${target}" >/dev/null
  scan_status=$?
  set -e

  if [ "${scan_status}" -eq 1 ]; then
    echo "[Trivy] HIGH or CRITICAL findings: ${name}" >&2
  elif [ "${scan_status}" -ne 0 ]; then
    echo "[Trivy] Scan execution failed: ${name} (exit ${scan_status})" >&2
  fi
  return "${scan_status}"
}

echo "[Trivy] Pulling pinned scanner image: ${TRIVY_IMAGE}" >&2
docker pull "${TRIVY_IMAGE}" >/dev/null

if scan_target repository fs /workspace --scanners vuln; then
  :
else
  merge_status "$?"
fi

if scan_target dockerfile config /workspace/Dockerfile; then
  :
else
  merge_status "$?"
fi

if scan_target image image "${IMAGE_REF}" --scanners vuln; then
  :
else
  merge_status "$?"
fi

echo "[Trivy] Reports written to ${REPORTS_DIR}" >&2
exit "${overall_status}"
