#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

REPO_TARGET="${REPO_TARGET:-${REPO_ROOT}}"
DOCKERFILE_PATH="${DOCKERFILE_PATH:-${REPO_ROOT}/Dockerfile}"
IMAGE_REF="${IMAGE_REF:-}"
IMAGE_FILTER="${IMAGE_FILTER:-*pgsql*custom*}"
IMAGE_LABEL_SELECTOR="${IMAGE_LABEL_SELECTOR:-org.opencontainers.image.title=PostgreSQL custom image}"
SEVERITY="${SEVERITY:-UNKNOWN,LOW,MEDIUM,HIGH,CRITICAL}"
FAIL_SEVERITY="${FAIL_SEVERITY:-HIGH,CRITICAL}"
REPORTS_DIR="${REPORTS_DIR:-${REPO_ROOT}/reports/trivy}"

mkdir -p "${REPORTS_DIR}"
timestamp="$(date -u +%Y%m%d-%H%M%S)"
report_base="${REPORTS_DIR}/${timestamp}"
overall_status=0

merge_status() {
  local candidate="$1"
  if (( candidate > overall_status )); then
    overall_status="${candidate}"
  fi
}

sanitize_label() {
  printf '%s\n' "${1//[^a-zA-Z0-9_.-]/_}"
}

run_scan() {
  local name="$1"
  local mode="$2"
  shift 2

  local text_report="${report_base}.${name}.txt"
  local json_report="${report_base}.${name}.json"
  local scan_status=0

  echo "[trivy] ${mode} scan: ${name}" >&2
  trivy "${mode}" --scanners vuln --severity "${SEVERITY}" "$@" | tee "${text_report}"
  trivy "${mode}" --scanners vuln --severity "${SEVERITY}" --format json --output "${json_report}" "$@"

  set +e
  trivy "${mode}" --scanners vuln --severity "${FAIL_SEVERITY}" --exit-code 1 --quiet "$@" >/dev/null
  scan_status=$?
  set -e
  return "${scan_status}"
}

if ! command -v trivy >/dev/null 2>&1; then
  echo 'Trivy is required. Install it or run the CI workflow.' >&2
  exit 2
fi
if [ ! -f "${DOCKERFILE_PATH}" ]; then
  echo "Dockerfile not found: ${DOCKERFILE_PATH}" >&2
  exit 2
fi

if run_scan repository fs --skip-dirs "${REPORTS_DIR}" "${REPO_TARGET}"; then
  :
else
  merge_status "$?"
fi

if run_scan dockerfile config "${DOCKERFILE_PATH}"; then
  :
else
  merge_status "$?"
fi

declare -a image_refs=()
if [ -n "${IMAGE_REF}" ]; then
  image_refs=("${IMAGE_REF}")
else
  while IFS= read -r image_id; do
    if [ -n "${image_id}" ]; then
      image_refs+=("${image_id}")
    fi
  done < <(docker image ls --filter "label=${IMAGE_LABEL_SELECTOR}" --format '{{.ID}}' | sort -u)

  while IFS= read -r reference; do
    # shellcheck disable=SC2053 # IMAGE_FILTER is intentionally a shell glob.
    if [[ "${reference}" == ${IMAGE_FILTER} ]] && [ "${reference}" != '<none>:<none>' ]; then
      image_refs+=("${reference}")
    fi
  done < <(docker image ls --format '{{.Repository}}:{{.Tag}}' | sort -u)
fi

if [ "${#image_refs[@]}" -eq 0 ]; then
  echo 'No images matched. Set IMAGE_REF explicitly or build a custom image first.' >&2
  exit 2
fi

declare -A seen_image_ids=()
for image in "${image_refs[@]}"; do
  image_id="$(docker image inspect --format '{{.Id}}' "${image}" 2>/dev/null || true)"
  [ -z "${image_id}" ] && continue
  [ -n "${seen_image_ids[${image_id}]+x}" ] && continue
  seen_image_ids["${image_id}"]=1

  if run_scan "image-$(sanitize_label "${image}")" image "${image}"; then
    :
  else
    merge_status "$?"
  fi
done

echo "Reports written to ${REPORTS_DIR}" >&2
exit "${overall_status}"
