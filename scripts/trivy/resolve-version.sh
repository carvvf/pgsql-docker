#!/usr/bin/env bash
set -euo pipefail

# Local and CI scans follow the newest published patch release of this Trivy
# minor series, so scanner and vulnerability-matching fixes arrive without a
# repository change. Moving to another minor series is a deliberate edit here.
#
# Prints the resolved version without a "v" prefix (for example 0.76.1).
# --series prints the minor series instead. TRIVY_VERSION selects an explicit
# release, which must belong to the series and be published. GH_TOKEN or
# GITHUB_TOKEN, or else an authenticated GitHub CLI, raises the GitHub API rate
# limit; anonymous requests also work.
TRIVY_SERIES='0.76'
TRIVY_RELEASES_URL='https://api.github.com/repos/aquasecurity/trivy/releases?per_page=100'

trivy_version_error() {
  printf 'Trivy version error: %s\n' "$1" >&2
  exit 1
}

if [ "${1:-}" = '--series' ]; then
  printf '%s\n' "${TRIVY_SERIES}"
  exit 0
fi

for required in curl jq; do
  command -v "${required}" >/dev/null || trivy_version_error "${required} is required."
done

series_pattern="^${TRIVY_SERIES//./\\.}\\.[0-9]+$"
requested="${TRIVY_VERSION:-}"
requested="${requested#v}"
if [ -n "${requested}" ] && [[ ! "${requested}" =~ ${series_pattern} ]]; then
  trivy_version_error "A Trivy ${TRIVY_SERIES}.x release is required: ${requested}"
fi

token="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
if [ -z "${token}" ] && command -v gh >/dev/null; then
  token="$(gh auth token 2>/dev/null || true)"
fi
headers=(-H 'Accept: application/vnd.github+json')
if [ -n "${token}" ]; then
  headers+=(-H "Authorization: Bearer ${token}")
fi

releases="$(curl --fail --silent --show-error --location "${headers[@]}" "${TRIVY_RELEASES_URL}")"
# Published releases only: drafts and pre-releases are never selected.
version="$(jq -r --arg pattern "${series_pattern}" --arg requested "${requested}" '
  [ .[]
    | select(.draft == false and .prerelease == false)
    | .tag_name | ltrimstr("v")
    | select(test($pattern) and ($requested == "" or . == $requested)) ]
  | max_by(split(".") | map(tonumber)) // empty
' <<<"${releases}")"
if [ -z "${version}" ]; then
  trivy_version_error "No published Trivy ${requested:-${TRIVY_SERIES}.x} release is listed at ${TRIVY_RELEASES_URL}."
fi
printf '%s\n' "${version}"
