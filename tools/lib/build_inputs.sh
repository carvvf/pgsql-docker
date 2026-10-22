#!/usr/bin/env bash
# Shared resolution of official release signals and immutable build inputs.

build_input_error() {
  printf 'Build input error: %s\n' "$1" >&2
  return 1
}

pull_image_digest() {
  local reference="$1"
  local digest
  docker pull --platform linux/amd64 "${reference}" >&2 || return
  if [[ "${reference}" == *@* ]]; then
    digest="${reference##*@}"
  else
    digest="$(docker image inspect "${reference}" --format '{{index .RepoDigests 0}}')" || return
    digest="${digest##*@}"
  fi
  if [[ ! "${digest}" =~ ^sha256:[a-f0-9]{64}$ ]]; then
    build_input_error "Invalid manifest digest for ${reference}: ${digest}"
    return 1
  fi
  printf '%s\n' "${digest}"
}

resolve_source_revision() {
  local repository="$1" tag="$2" expected="$3" revisions revision
  revisions="$(git ls-remote --tags --exit-code "${repository}" "refs/tags/${tag}" "refs/tags/${tag}^{}")" || return
  revision="$(awk '$2 ~ /\^\{\}$/ { print $1; exit }' <<<"${revisions}")"
  if [ -z "${revision}" ]; then
    revision="$(awk 'NR == 1 { print $1 }' <<<"${revisions}")"
  fi
  if [[ ! "${revision}" =~ ^[a-f0-9]{40}$ ]]; then
    build_input_error "Could not resolve source tag ${tag} in ${repository}."
    return 1
  fi
  if [ -n "${expected}" ] && [ "${expected}" != "${revision}" ]; then
    build_input_error "The requested source commit does not match ${tag} in ${repository}."
    return 1
  fi
  printf '%s\n' "${revision}"
}

# The gosu builder follows the newest stable patch release of this Go minor
# series, so a Go standard-library fix reaches the next build without a
# repository change. Moving to another minor series is a deliberate edit here.
GO_TOOLCHAIN_SERIES='1.27'
GO_RELEASES_URL='https://go.dev/dl/?mode=json&include=all'

resolve_go_toolchain() {
  local requested_version="${GO_TOOLCHAIN_VERSION:-}"
  local requested_sha256="${GO_TOOLCHAIN_SHA256:-}"
  local series_pattern="^${GO_TOOLCHAIN_SERIES//./\\.}\\.[0-9]+$"
  local releases resolved
  if [ -n "${requested_version}" ] && [[ ! "${requested_version}" =~ ${series_pattern} ]]; then
    build_input_error "A Go ${GO_TOOLCHAIN_SERIES}.x toolchain version is required: ${requested_version}"
    return 1
  fi
  if [ -n "${requested_sha256}" ] && [[ ! "${requested_sha256}" =~ ^[a-f0-9]{64}$ ]]; then
    build_input_error "Invalid requested Go toolchain SHA-256: ${requested_sha256}"
    return 1
  fi
  releases="$(curl --fail --silent --show-error --location "${GO_RELEASES_URL}")" || return
  # Only stable releases (no betas or release candidates) and the official
  # linux/amd64 archive, whose SHA-256 the Dockerfile verifies before use.
  resolved="$(jq -r --arg pattern "${series_pattern}" --arg series "${GO_TOOLCHAIN_SERIES}" --arg requested "${requested_version}" '
    [ .[]
      | select(.stable == true)
      | (.version | ltrimstr("go")) as $version
      | select(($version | test($pattern)) and ($requested == "" or $version == $requested))
      | {
          version: $version,
          patch: ($version | ltrimstr($series + ".") | tonumber),
          sha256: ([.files[]? | select(.os == "linux" and .arch == "amd64" and .kind == "archive") | .sha256][0] // "")
        } ]
    | max_by(.patch) // empty
    | "\(.version) \(.sha256)"
  ' <<<"${releases}")" || {
    build_input_error "Could not parse the Go release index from ${GO_RELEASES_URL}."
    return 1
  }
  if [ -z "${resolved}" ]; then
    build_input_error "No stable Go ${requested_version:-${GO_TOOLCHAIN_SERIES}.x} release is listed at ${GO_RELEASES_URL}."
    return 1
  fi
  go_toolchain_version="${resolved%% *}"
  go_toolchain_sha256="${resolved#* }"
  if [[ ! "${go_toolchain_sha256}" =~ ^[a-f0-9]{64}$ ]]; then
    build_input_error "Go ${go_toolchain_version} has no valid linux/amd64 archive SHA-256."
    return 1
  fi
  if [ -n "${requested_sha256}" ] && [ "${requested_sha256}" != "${go_toolchain_sha256}" ]; then
    build_input_error "The requested Go toolchain SHA-256 does not match Go ${go_toolchain_version}."
    return 1
  fi
}

resolve_build_inputs() {
  local required
  for required in docker git awk curl jq; do
    command -v "${required}" >/dev/null || { build_input_error "${required} is required."; return 1; }
  done
  if [ "${PG_MAJOR:-18}" != '18' ]; then
    build_input_error 'Only PostgreSQL major 18 is supported; a major upgrade requires a coordinated migration.'
    return 1
  fi
  local requested_version="${POSTGRES_UPSTREAM_VERSION:-}"
  local requested_source="${POSTGRES_SOURCE_REF:-}"
  local requested_digest="${POSTGRES_UPSTREAM_DIGEST:-}"
  local image_environment pg_version_full official_major official_gosu_version
  if [ -n "${requested_source}" ]; then
    if [[ ! "${requested_source}" =~ ^REL_18_([0-9]+)$ ]]; then
      build_input_error "A PostgreSQL major 18 release tag is required: ${requested_source}"
      return 1
    fi
    if [ -z "${requested_version}" ]; then
      requested_version="18.${BASH_REMATCH[1]}"
    fi
  fi
  if [ -n "${requested_version}" ] && [[ ! "${requested_version}" =~ ^18\.[0-9]+$ ]]; then
    build_input_error "A PostgreSQL major 18 version is required: ${requested_version}"
    return 1
  fi
  if [ -n "${requested_digest}" ] && [[ ! "${requested_digest}" =~ ^sha256:[a-f0-9]{64}$ ]]; then
    build_input_error "Invalid requested PostgreSQL digest: ${requested_digest}"
    return 1
  fi
  upstream_ref="${POSTGRES_UPSTREAM_REF:-}"
  if [ -z "${upstream_ref}" ]; then
    if [ -n "${requested_digest}" ]; then
      upstream_ref="postgres@${requested_digest}"
    else
      upstream_ref="postgres:${requested_version:-18}"
    fi
  fi
  if [[ ! "${upstream_ref}" =~ ^postgres(:18(\.[0-9]+)?(-[A-Za-z0-9_.-]+)?|@sha256:[a-f0-9]{64})$ ]]; then
    build_input_error "An official PostgreSQL major 18 reference is required: ${upstream_ref}"
    return 1
  fi
  upstream_digest="$(pull_image_digest "${upstream_ref}")"
  if [ -n "${requested_digest}" ] && [ "${requested_digest}" != "${upstream_digest}" ]; then
    build_input_error 'The requested PostgreSQL digest does not match the official image.'
    return 1
  fi
  upstream_ref="postgres@${upstream_digest}"
  image_environment="$(docker image inspect "${upstream_ref}" --format '{{range .Config.Env}}{{println .}}{{end}}')"
  pg_version_full="$(awk '/^PG_VERSION=/ { print substr($0, 12); exit }' <<<"${image_environment}")"
  official_major="$(awk '/^PG_MAJOR=/ { print substr($0, 10); exit }' <<<"${image_environment}")"
  official_gosu_version="$(awk '/^GOSU_VERSION=/ { print substr($0, 14); exit }' <<<"${image_environment}")"
  upstream_version="${pg_version_full%%-*}"
  if [ "${official_major}" != '18' ] || [[ ! "${upstream_version}" =~ ^18\.[0-9]+$ ]]; then
    build_input_error "The official image must contain PostgreSQL major 18: ${pg_version_full}"
    return 1
  fi
  if [ -n "${requested_version}" ] && [ "${requested_version}" != "${upstream_version}" ]; then
    build_input_error 'The requested PostgreSQL version does not match the official image.'
    return 1
  fi
  source_ref="REL_${upstream_version//./_}"
  if [ -n "${requested_source}" ] && [ "${requested_source}" != "${source_ref}" ]; then
    build_input_error 'The PostgreSQL source tag must match the official image version.'
    return 1
  fi
  source_revision="$(resolve_source_revision https://github.com/postgres/postgres.git "${source_ref}" "${POSTGRES_SOURCE_REVISION:-}")"
  gosu_source_ref="${GOSU_SOURCE_REF:-${official_gosu_version}}"
  if [[ ! "${gosu_source_ref}" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
    build_input_error "Unsupported gosu release tag: ${gosu_source_ref}"
    return 1
  fi
  gosu_source_revision="$(resolve_source_revision https://github.com/tianon/gosu.git "${gosu_source_ref}" "${GOSU_SOURCE_REVISION:-}")"
  entrypoint_source_commit="${ENTRYPOINT_SOURCE_COMMIT:-}"
  if [ -z "${entrypoint_source_commit}" ]; then
    entrypoint_source_commit="$(git ls-remote --exit-code https://github.com/docker-library/postgres.git refs/heads/master | awk 'NR == 1 { print $1 }')"
  fi
  if [[ ! "${entrypoint_source_commit}" =~ ^[a-f0-9]{40}$ ]]; then
    build_input_error 'A valid docker-library/postgres entrypoint commit is required.'
    return 1
  fi

  requested_digest="${UBUNTU_BASE_DIGEST:-}"
  if [ -n "${requested_digest}" ] && [[ ! "${requested_digest}" =~ ^sha256:[a-f0-9]{64}$ ]]; then
    build_input_error "Invalid requested Ubuntu digest: ${requested_digest}"
    return 1
  fi
  ubuntu_base_ref="${UBUNTU_BASE_IMAGE:-}"
  if [ -z "${ubuntu_base_ref}" ]; then
    ubuntu_base_ref="ubuntu:24.04"
    if [ -n "${requested_digest}" ]; then
      ubuntu_base_ref="ubuntu@${requested_digest}"
    fi
  fi
  if [[ ! "${ubuntu_base_ref}" =~ ^ubuntu(:24\.04|@sha256:[a-f0-9]{64})$ ]]; then
    build_input_error "An official Ubuntu 24.04 reference is required: ${ubuntu_base_ref}"
    return 1
  fi
  ubuntu_base_digest="$(pull_image_digest "${ubuntu_base_ref}")"
  if [ -n "${requested_digest}" ] && [ "${requested_digest}" != "${ubuntu_base_digest}" ]; then
    build_input_error 'The requested Ubuntu digest does not match the runtime image.'
    return 1
  fi
  ubuntu_base_ref="ubuntu@${ubuntu_base_digest}"
  local ubuntu_version
  ubuntu_version="$(docker image inspect "${ubuntu_base_ref}" --format '{{index .Config.Labels "org.opencontainers.image.version"}}')"
  if [ "${ubuntu_version}" != '24.04' ]; then
    build_input_error "Ubuntu 24.04 is required; resolved ${ubuntu_version}."
    return 1
  fi
  resolve_go_toolchain || return
  printf 'Resolved PostgreSQL %s at %s; gosu %s at %s built with Go %s; entrypoint %s; Ubuntu %s.\n' \
    "${upstream_version}" "${source_revision}" "${gosu_source_ref}" "${gosu_source_revision}" \
    "${go_toolchain_version}" "${entrypoint_source_commit}" "${ubuntu_base_digest}" >&2
}

write_build_inputs() {
  printf '%s\n' \
    "upstream_ref=${upstream_ref}" \
    "upstream_version=${upstream_version}" \
    "upstream_digest=${upstream_digest}" \
    "source_ref=${source_ref}" \
    "source_revision=${source_revision}" \
    "gosu_source_ref=${gosu_source_ref}" \
    "gosu_source_revision=${gosu_source_revision}" \
    "go_toolchain_version=${go_toolchain_version}" \
    "go_toolchain_sha256=${go_toolchain_sha256}" \
    "entrypoint_source_commit=${entrypoint_source_commit}" \
    "ubuntu_base_ref=${ubuntu_base_ref}" \
    "ubuntu_base_digest=${ubuntu_base_digest}"
}
