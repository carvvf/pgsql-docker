# syntax=docker/dockerfile:1
# The PostgreSQL release and its two auxiliary sources (gosu, and the
# docker-library/postgres entrypoint scripts) are resolved locally and in CI
# against postgres:<POSTGRES_MAJOR>, its recorded gosu release, and docker-library/postgres's
# current master, respectively. See AGENTS.md "Security and update policy".
ARG POSTGRES_SOURCE_REPOSITORY=https://github.com/postgres/postgres.git
ARG POSTGRES_SOURCE_REF
ARG POSTGRES_SOURCE_REVISION
ARG GOSU_SOURCE_REPOSITORY=https://github.com/tianon/gosu.git
ARG GOSU_SOURCE_REF
ARG GOSU_SOURCE_REVISION
ARG ENTRYPOINT_SOURCE_REPOSITORY=https://github.com/docker-library/postgres.git
ARG ENTRYPOINT_SOURCE_COMMIT
# Every resolved build passes the Ubuntu reference and release from
# UBUNTU_SERIES in tools/lib/build_inputs.sh. This default serves direct builds
# only, as BuildKit requires a valid default for an ARG used in FROM;
# tests/test_build_inputs.py keeps it equal to UBUNTU_SERIES.
ARG UBUNTU_BASE_IMAGE=ubuntu:24.04
# Passed by every build from POSTGRES_MAJOR in tools/lib/build_inputs.sh; it has no
# default, so a build without it stops in the source stage.
ARG PG_MAJOR
# An Ubuntu release's "golang-go" apt package stays at the Go minor it shipped
# with (Go 1.22 for 24.04), which in time carries a long list of fixed Go standard
# library CVEs (net/http, crypto/tls, encoding/*, ...) that end up
# statically embedded in any binary it compiles, including gosu, even though
# gosu itself barely touches those packages. Building gosu with a current,
# checksum-verified upstream Go toolchain instead of the distro package
# avoids shipping that stale stdlib. tools/lib/build_inputs.sh resolves the
# newest stable patch release of the pinned Go minor series, with its official
# linux/amd64 archive SHA-256, from https://go.dev/dl/?mode=json&include=all.
ARG GO_TOOLCHAIN_VERSION
ARG GO_TOOLCHAIN_SHA256

# All three sources are resolved on the same base as the runtime image, not a
# separate build distro: the compiled `postgres`/`psql` binaries dynamically
# link libssl, libcrypto, libz, and libreadline, so the toolchain that
# compiles them must share glibc/OpenSSL/readline sonames with the image that
# runs them.
# hadolint ignore=DL3006
FROM ${UBUNTU_BASE_IMAGE} AS source
ARG POSTGRES_SOURCE_REPOSITORY
ARG POSTGRES_SOURCE_REF
ARG POSTGRES_SOURCE_REVISION
ARG GOSU_SOURCE_REPOSITORY
ARG GOSU_SOURCE_REF
ARG GOSU_SOURCE_REVISION
ARG ENTRYPOINT_SOURCE_REPOSITORY
ARG ENTRYPOINT_SOURCE_COMMIT
ARG PG_MAJOR

# hadolint ignore=DL3008
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates git \
    && rm -rf /var/lib/apt/lists/*

RUN test -n "${PG_MAJOR}" \
    && case "${POSTGRES_SOURCE_REF}" in "REL_${PG_MAJOR}_"*) ;; *) echo "A PostgreSQL major ${PG_MAJOR} release tag is required." >&2; exit 1 ;; esac \
    && test -n "${POSTGRES_SOURCE_REF}" \
    && test -n "${POSTGRES_SOURCE_REVISION}" \
    && git clone --depth 1 --branch "${POSTGRES_SOURCE_REF}" \
      "${POSTGRES_SOURCE_REPOSITORY}" /source/postgres \
    && actual_revision="$(git -C /source/postgres rev-parse HEAD)" \
    && test "${actual_revision}" = "${POSTGRES_SOURCE_REVISION}" \
    && printf '%s\n' "${actual_revision}" > /source/postgres-revision

RUN test -n "${GOSU_SOURCE_REF}" \
    && test -n "${GOSU_SOURCE_REVISION}" \
    && git clone --depth 1 --branch "${GOSU_SOURCE_REF}" \
      "${GOSU_SOURCE_REPOSITORY}" /source/gosu \
    && actual_revision="$(git -C /source/gosu rev-parse HEAD)" \
    && test "${actual_revision}" = "${GOSU_SOURCE_REVISION}" \
    && printf '%s\n' "${actual_revision}" > /source/gosu-revision

# docker-library/postgres does not tag releases; pin by commit instead of a
# ref, and verify the checked-out commit matches it exactly.
RUN test -n "${ENTRYPOINT_SOURCE_COMMIT}" \
    && mkdir -p /source/docker-library-postgres \
    && git -C /source/docker-library-postgres init -q \
    && git -C /source/docker-library-postgres remote add origin "${ENTRYPOINT_SOURCE_REPOSITORY}" \
    && git -C /source/docker-library-postgres fetch -q --depth 1 origin "${ENTRYPOINT_SOURCE_COMMIT}" \
    && git -C /source/docker-library-postgres checkout -q "${ENTRYPOINT_SOURCE_COMMIT}" \
    && actual_revision="$(git -C /source/docker-library-postgres rev-parse HEAD)" \
    && test "${actual_revision}" = "${ENTRYPOINT_SOURCE_COMMIT}" \
    && printf '%s\n' "${actual_revision}" > /source/entrypoint-revision

# hadolint ignore=DL3006
FROM ${UBUNTU_BASE_IMAGE} AS gosu-builder
ARG GO_TOOLCHAIN_VERSION
ARG GO_TOOLCHAIN_SHA256
# hadolint ignore=DL3008
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl \
    && rm -rf /var/lib/apt/lists/*
RUN if [ -z "${GO_TOOLCHAIN_VERSION}" ] || [ -z "${GO_TOOLCHAIN_SHA256}" ]; then \
      echo 'GO_TOOLCHAIN_VERSION and GO_TOOLCHAIN_SHA256 are required build arguments.' >&2; \
      exit 1; \
    fi
# hadolint ignore=DL4006
RUN curl --fail --silent --show-error --location \
      "https://go.dev/dl/go${GO_TOOLCHAIN_VERSION}.linux-amd64.tar.gz" \
      -o /tmp/go.tar.gz \
    && echo "${GO_TOOLCHAIN_SHA256}  /tmp/go.tar.gz" | sha256sum -c - \
    && tar -C /usr/local -xzf /tmp/go.tar.gz \
    && rm /tmp/go.tar.gz
ENV PATH="/usr/local/go/bin:${PATH}"
COPY --from=source /source/gosu /source/gosu
COPY build/gosu-modules/go.mod build/gosu-modules/go.sum /tmp/gosu-modules/
WORKDIR /source/gosu
ENV CGO_ENABLED=0 \
    GOTOOLCHAIN=local \
    GOSUMDB=sum.golang.org
# Disable both local Go telemetry counters and uploads before compiling gosu.
# Upgrade the upstream module pins to the direct requirements of
# build/gosu-modules/go.mod, using the checksums committed in its go.sum. The
# module list is split into separate go get arguments on purpose.
# hadolint ignore=SC2086
RUN --mount=type=cache,target=/root/go/pkg/mod,id=pgsql-docker-gosu-gomod,sharing=locked \
    go telemetry off \
    && modules="$(awk '/^require \(/ { block = 1; next } block && /^\)/ { block = 0 } \
        block && !/indirect/ { print $1 "@" $2 } /^require [^(]/ && !/indirect/ { print $2 "@" $3 }' \
        /tmp/gosu-modules/go.mod)" \
    && test -n "${modules}" \
    && cat /tmp/gosu-modules/go.sum >> go.sum \
    && go get ${modules} \
    && go mod verify \
    && go build -mod=readonly -trimpath -ldflags '-s -w' -o /out/gosu . \
    && /out/gosu --version

# hadolint ignore=DL3006
FROM ${UBUNTU_BASE_IMAGE} AS postgres-builder
# hadolint ignore=DL3008
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
      bison \
      build-essential \
      flex \
      libreadline-dev \
      libssl-dev \
      meson \
      ninja-build \
      pkg-config \
      python3 \
      zlib1g-dev \
    && rm -rf /var/lib/apt/lists/*

COPY --from=source /source/postgres /source/postgres
WORKDIR /source/postgres

# Feature set deliberately narrower than the official image: every disabled
# option here is an optional dependency (ICU, LLVM JIT, libxml/libxslt, LDAP,
# GSSAPI, PAM, systemd, PL/Perl, PL/Python, PL/Tcl, ...) that Ragtime's
# contract does not use (see AGENTS.md "Image and downstream compatibility
# contract"), and each one is a package this image does not have to carry or
# patch. OpenSSL and readline stay enabled because Ragtime's TLS overlay and
# interactive psql use depend on them. ICU stays disabled because Ragtime
# pins collation via `--locale-provider=builtin`, which needs neither ICU nor
# glibc locale data.
RUN meson setup build --prefix=/usr/local/pgsql --buildtype=release \
      -Dssl=openssl \
      -Dreadline=enabled \
      -Dzlib=enabled \
      -Dicu=disabled \
      -Dnls=disabled \
      -Dllvm=disabled \
      -Dlibxml=disabled \
      -Dlibxslt=disabled \
      -Dldap=disabled \
      -Dgssapi=disabled \
      -Dpam=disabled \
      -Dbsd_auth=disabled \
      -Dbonjour=disabled \
      -Dsystemd=disabled \
      -Dselinux=disabled \
      -Ddtrace=disabled \
      -Duuid=none \
      -Dplperl=disabled \
      -Dplpython=disabled \
      -Dpltcl=disabled
RUN ninja -C build
RUN ninja -C build install
RUN /usr/local/pgsql/bin/postgres --version

# The workflow resolves this mutable tag to an immutable manifest digest.
# hadolint ignore=DL3006
FROM ${UBUNTU_BASE_IMAGE} AS runtime

ARG POSTGRES_SOURCE_REPOSITORY
ARG POSTGRES_SOURCE_REF
ARG POSTGRES_SOURCE_REVISION
ARG POSTGRES_UPSTREAM_VERSION=unknown
ARG POSTGRES_UPSTREAM_DIGEST=unknown
ARG POSTGRES_IMAGE_VERSION
ARG GOSU_SOURCE_REPOSITORY
ARG GOSU_SOURCE_REF
ARG GOSU_SOURCE_REVISION
ARG GO_TOOLCHAIN_VERSION
ARG GO_TOOLCHAIN_SHA256
ARG ENTRYPOINT_SOURCE_REPOSITORY
ARG ENTRYPOINT_SOURCE_COMMIT
ARG UBUNTU_BASE_IMAGE
ARG UBUNTU_BASE_DIGEST=unknown
ARG UBUNTU_SERIES
ARG PG_MAJOR
ARG SOURCE_REPOSITORY=https://github.com/carvvf/pgsql-docker

LABEL org.opencontainers.image.title="PostgreSQL custom image"
LABEL org.opencontainers.image.description="PostgreSQL rebuilt from verified source on Ubuntu ${UBUNTU_SERIES}"
LABEL org.opencontainers.image.documentation="${SOURCE_REPOSITORY}"
LABEL org.opencontainers.image.source="${SOURCE_REPOSITORY}"
LABEL org.opencontainers.image.url="${SOURCE_REPOSITORY}"
LABEL org.opencontainers.image.version="${POSTGRES_IMAGE_VERSION}"
LABEL io.github.carvvf.pgsql-docker.postgres.source.repository="${POSTGRES_SOURCE_REPOSITORY}"
LABEL io.github.carvvf.pgsql-docker.postgres.source.ref="${POSTGRES_SOURCE_REF}"
LABEL io.github.carvvf.pgsql-docker.postgres.source.revision="${POSTGRES_SOURCE_REVISION}"
LABEL io.github.carvvf.pgsql-docker.postgres.upstream.version="${POSTGRES_UPSTREAM_VERSION}"
LABEL io.github.carvvf.pgsql-docker.postgres.upstream.digest="${POSTGRES_UPSTREAM_DIGEST}"
LABEL io.github.carvvf.pgsql-docker.postgres.major="${PG_MAJOR}"
LABEL io.github.carvvf.pgsql-docker.gosu.source.repository="${GOSU_SOURCE_REPOSITORY}"
LABEL io.github.carvvf.pgsql-docker.gosu.source.ref="${GOSU_SOURCE_REF}"
LABEL io.github.carvvf.pgsql-docker.gosu.source.revision="${GOSU_SOURCE_REVISION}"
LABEL io.github.carvvf.pgsql-docker.gosu.go.version="${GO_TOOLCHAIN_VERSION}"
LABEL io.github.carvvf.pgsql-docker.gosu.go.sha256="${GO_TOOLCHAIN_SHA256}"
LABEL io.github.carvvf.pgsql-docker.entrypoint.source.repository="${ENTRYPOINT_SOURCE_REPOSITORY}"
LABEL io.github.carvvf.pgsql-docker.entrypoint.source.commit="${ENTRYPOINT_SOURCE_COMMIT}"
LABEL io.github.carvvf.pgsql-docker.runtime.base.image="${UBUNTU_BASE_IMAGE}"
LABEL io.github.carvvf.pgsql-docker.runtime.base.digest="${UBUNTU_BASE_DIGEST}"

# Forces a fresh apt-get run on every build even when GHA layer caching would
# otherwise reuse this layer unchanged (same base digest, same PostgreSQL
# source revision): apt mirrors publish OS security patches far more often
# than the Ubuntu tag digest changes, and this layer is how those
# patches reach the image.
ARG CACHEBUST=unknown

ENV DEBIAN_FRONTEND=noninteractive
# libreadline8/zlib1g/libssl3 satisfy the shared libraries `postgres`/`psql`
# link against (verified with ldd against the postgres-builder output); no
# -dev packages are needed at runtime.
# hadolint ignore=DL3008
RUN apt-get update \
    && apt-get upgrade -y \
    && apt-get install -y --no-install-recommends \
      ca-certificates \
      libreadline8 \
      libssl3 \
      tzdata \
      zlib1g \
    && rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*

COPY --from=postgres-builder /usr/local/pgsql /usr/local/pgsql
COPY --from=gosu-builder /out/gosu /usr/local/bin/gosu

ENV PATH="/usr/local/pgsql/bin:${PATH}"

# Mirrors docker-library/postgres's own uid/gid and directory modes exactly:
# Ragtime's AppArmor profile and bootstrap capability set
# (CHOWN/DAC_OVERRIDE/FOWNER/SETGID/SETUID) assume this precise sequence
# (start root, repair ownership, gosu-drop to this fixed uid). See AGENTS.md
# "Image and downstream compatibility contract".
RUN groupadd -r postgres --gid=999 \
    && useradd -r -g postgres --uid=999 --home-dir=/var/lib/postgresql --shell=/bin/bash postgres \
    && install --verbose --directory --owner postgres --group postgres --mode 1777 /var/lib/postgresql \
    && install --verbose --directory --owner postgres --group postgres --mode 3777 /var/run/postgresql \
    && mkdir -p /docker-entrypoint-initdb.d \
    && gosu postgres true

# In PostgreSQL 18+, PGDATA moved to a major-version-specific subdirectory
# (matching the pg_ctlcluster convention) so that a single
# /var/lib/postgresql volume mount survives a future pg_upgrade. Ragtime
# mounts the whole parent directory for exactly this reason; do not shorten
# this back to /var/lib/postgresql/data.
ENV PG_MAJOR=${PG_MAJOR} \
    PGDATA=/var/lib/postgresql/${PG_MAJOR}/docker \
    LANG=C.UTF-8

# Vendored from docker-library/postgres at ENTRYPOINT_SOURCE_COMMIT (pinned
# above), copied out of the same resolved clone used to record that commit in
# the labels, rather than a static copy kept in this repository: first-run
# initdb detection, the POSTGRES_USER/PASSWORD/DB and POSTGRES_INITDB_ARGS
# handling, and the docker-entrypoint-initdb.d processing order all have real
# correctness and security stakes that the upstream scripts already get
# right, and this guarantees the shipped script always matches the pinned
# commit recorded in the image labels. The "bookworm" variant is used
# because its script content was the one validated locally; the generic bash
# it contains does not assume a Debian runtime.
COPY --from=source /source/docker-library-postgres/${PG_MAJOR}/bookworm/docker-entrypoint.sh /source/docker-library-postgres/${PG_MAJOR}/bookworm/docker-ensure-initdb.sh /usr/local/bin/
RUN ln -sT docker-ensure-initdb.sh /usr/local/bin/docker-enforce-initdb.sh

RUN mkdir -p /licenses
COPY --from=source /source/postgres/COPYRIGHT /licenses/PostgreSQL-COPYRIGHT.txt
COPY --from=source /source/gosu/LICENSE /licenses/gosu-Apache-2.0.txt
COPY --from=source /source/docker-library-postgres/LICENSE /licenses/docker-library-postgres-MIT.txt

# Keep the official image's runtime contract: Ragtime's bootstrap capability
# set and persistent-volume setup depend on it.
VOLUME /var/lib/postgresql

# Matches PostgreSQL's "Fast Shutdown" semantics: new connections are
# refused and in-progress transactions are aborted so the server can flush
# and stop cleanly. See https://www.postgresql.org/docs/current/server-shutdown.html.
STOPSIGNAL SIGINT

EXPOSE 5432

ENTRYPOINT ["docker-entrypoint.sh"]
CMD ["postgres"]
