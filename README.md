# PostgreSQL custom image

> [!NOTE]
> **Written with AI assistance.** This document was generated with the help of an AI
> assistant and may contain inaccuracies. Verify anything critical against the source code.

This repository publishes a hardened `linux/amd64` PostgreSQL image compiled
from the verified upstream source release corresponding to `postgres:18`.
Its final runtime base is `ubuntu:24.04`.

Its daily GitHub Actions workflow resolves the official-image manifest digest,
the matching PostgreSQL source tag and commit, the pinned `gosu` and
`docker-library/postgres` entrypoint-script sources, and the Ubuntu runtime
manifest digest. It rebuilds when any of these change or when the active image
was built from another commit of this repository, scans the candidate
with Trivy, and publishes it to GHCR only if HIGH and CRITICAL OS or library
findings are absent.

The runtime interface intentionally remains compatible with the official
image and with Ragtime's PostgreSQL deployment:

- PostgreSQL on port `5432`
- `docker-entrypoint.sh` as the image entrypoint, vendored from
  `docker-library/postgres` rather than reimplemented
- starts as root, repairs data-volume ownership, then drops privileges to a
  fixed `postgres` uid/gid (999) via `gosu` — required verbatim because
  Ragtime's healthcheck and AppArmor profile assume this exact sequence
- persistent data at `/var/lib/postgresql` (PostgreSQL 18+ places the actual
  data directory at the major-version-specific `/var/lib/postgresql/18/docker`
  subpath within that mount)
- `initdb --locale-provider=builtin --builtin-locale=C.UTF-8`, decoupling
  collation from OS glibc/ICU packages so that OS patch rebuilds cannot
  silently change collation behavior against existing data
- `pg_stat_statements` available for `shared_preload_libraries`

See `AGENTS.md` for the full compatibility contract and the reasoning behind
each of these constraints.

The image is intentionally amd64-only. It does not publish an arm64 manifest.

## Image tags

Published images use two tags:

- `<postgres-version>-custom.<N>` is immutable and records the custom
  rebuild (for example `18.6-custom.3`).
- `latest` moves only after the candidate has passed the build, Trivy, and
  runtime test gates.

`latest` only ever tracks minor releases and OS-patch rebuilds within the
pinned PostgreSQL major version (18). A major-version move (to 19) is never
automatic: PostgreSQL's on-disk format is not compatible across major
versions, so that step is a deliberate, coordinated change requiring
`pg_upgrade` (or dump/restore) against Ragtime's data volume. See AGENTS.md
"Version and upgrade policy".

The daily workflow deliberately reports failure after a clean rebuild. This is
the downstream update signal: an operator should pull and redeploy the new
image rather than treating the notification as a failed publication.

For a controlled rollout, use an immutable tag. For example:

```yaml
image: ghcr.io/carvvf/pgsql-docker:18.6-custom.3
```

For a development deployment that tracks verified daily updates:

```yaml
image: ghcr.io/carvvf/pgsql-docker:latest
```

The GHCR package must be public or the deployment host must authenticate before
pulling it.

## Downstream update

The image is intended to replace the `postgres` service in Ragtime. Retain
the existing `postgres_data` volume while updating:

```bash
docker compose pull postgres
docker compose up -d postgres
```

Do not use `docker compose down -v` for an image update because it removes
the PostgreSQL data volume.

A PostgreSQL major-version update is a separate, explicit operation and must
never be performed with a routine pull/up: it requires `pg_upgrade` (or
dump/restore) against `postgres_data` before the new image can start
correctly.

## Local build and validation

Build the PostgreSQL 18 release currently identified by `postgres:18` from
source on Ubuntu 24.04, using the same input resolver as GitHub Actions:

```bash
bash tools/build_local_image.sh
```

The VS Code `Docker: build local image` task invokes this entrypoint. It pulls
the official `linux/amd64` image as a release signal, reads `PG_VERSION`,
`PG_MAJOR`, and `GOSU_VERSION`, resolves the matching PostgreSQL and gosu source
tags and commits, pins the `docker-library/postgres` master commit for the
entrypoint scripts, and resolves the Ubuntu 24.04 runtime manifest digest.
The official PostgreSQL image is not used as the runtime base. All resolved
values are passed explicitly to the Dockerfile; every source checkout must
match its expected commit. The entrypoint requires Bash, Docker, Git, and
network access to Docker Hub and GitHub; no Python environment is needed.

To select a specific release within the supported major version:

```bash
POSTGRES_SOURCE_REF=REL_18_6 bash tools/build_local_image.sh
```

`tools/lib/build_inputs.sh` owns the shared resolver used by the local build,
the standalone build workflow, daily scan, and publication preflight.
`bash tools/resolve_build_inputs.sh` prints resolved `key=value` outputs without
compiling or publishing an image. Optional environment inputs are
`POSTGRES_UPSTREAM_REF`, `POSTGRES_UPSTREAM_VERSION`, `POSTGRES_UPSTREAM_DIGEST`,
`POSTGRES_SOURCE_REF`, `POSTGRES_SOURCE_REVISION`, `GOSU_SOURCE_REF`,
`GOSU_SOURCE_REVISION`, `ENTRYPOINT_SOURCE_COMMIT`, `UBUNTU_BASE_IMAGE`, and
`UBUNTU_BASE_DIGEST`. Version, tag, commit, or digest mismatches abort resolution.
Gosu defaults to the version recorded in the official PostgreSQL image; an
explicit release override must resolve to its verified upstream commit.
Explicit digest references retain their release signal, and an explicit
entrypoint commit is retained and verified during the Dockerfile checkout.

The resolver rejects `postgres:latest`, references to other majors, and even
an explicitly pinned digest whose image reports a major other than 18.
Local builds pass `PG_MAJOR=18` explicitly. This preserves the existing data
format contract; a major upgrade remains a separate coordinated operation.
Ubuntu inputs must identify the official 24.04 image.

Local OCI versions use `<postgres-version>-local`; published images retain
`<postgres-version>-custom.<N>`. Both paths record all three source revisions,
the official-image digest, and the runtime-base digest. The image version label
is set explicitly instead of inheriting Ubuntu's `24.04` label. Direct Dockerfile
builds require verified source arguments; there are no static source-version
or entrypoint-commit fallbacks. Input parity and provenance do not guarantee
binary reproducibility across different build times. Publication still requires
the existing vulnerability and runtime gates.

The `gosu` build uses Go 1.27.2 with the official Linux amd64 archive SHA-256
verified before extraction. After verifying the upstream `gosu` source, it
updates `github.com/moby/sys/user` to `v0.4.1` and `golang.org/x/sys` to
`v0.44.0` to remediate their reported vulnerabilities. These are explicit
dependency updates to the upstream release, not an unmodified upstream build.
The archive and module pins replace the Go 1.27.1 and module v0.1.0 inputs
reported by Trivy; these Go dependency updates do not select PostgreSQL's source version.

`build/gosu-dependencies.sum` records the module archive and `go.mod` checksums
obtained from Go's public checksum database. They are merged into the upstream
`go.sum` before updating dependencies. Go checksum authentication remains
enabled, `go mod verify` checks the module cache, and `go build -mod=readonly`
prevents the compilation step from modifying dependency requirements.
`GOTOOLCHAIN=local` keeps compilation on the checksum-verified toolchain.
Local and GitHub Actions builds use this same Dockerfile and dependency policy.
Rebuild the image before scanning it; refreshing Ubuntu packages or rebuilding
unchanged dependency pins cannot update the Go code embedded in `gosu`.

Run resolver regression tests with Python 3's standard library. Docker and Git
are simulated; these tests require no daemon, network, or package installs:

```bash
python3 -m unittest discover -s tests -p test_build_inputs.py
```

The three build/scan/publish workflows run this check before resolving inputs.

Run the compatibility smoke test. It applies the relevant Ragtime container
restrictions, runs the real Ragtime bootstrap init flow (vendored as a test
fixture; see `tests/fixtures/postgres-init`), checks the server version against
its upstream image label, confirms `pg_stat_statements` and the builtin locale
provider, restarts the container, verifies
persistence, and removes the test resources:

```bash
IMAGE_REF=pgsql-custom:local bash tests/test-postgres-image.sh
```

To instead validate against the live Ragtime contract (catches drift between
the vendored fixture and the real bootstrap script), point `RAGTIME_REPO` at
a checked-out `ragtime-rag-orch`:

```bash
IMAGE_REF=pgsql-custom:local RAGTIME_REPO=../ragtime-rag-orch bash tests/test-postgres-image.sh
```

For a local Trivy filesystem, Dockerfile, and image scan, use the same
Trivy 0.75.0 container as CI; no host Trivy installation is required:

```bash
IMAGE_REF=pgsql-custom:local bash tools/dev_trivy_scan.sh
```

Alternatively, install Trivy 0.75.0 on the host and run
`IMAGE_REF=pgsql-custom:local scripts/trivy/scan-image.sh`.
This entrypoint rejects other host versions to keep scans aligned with CI.

## Telemetry policy

The `gosu` builder runs `go telemetry off` before compilation, disabling
both local toolchain counters and uploads through Go's documented control.
The same Dockerfile is used locally and in GitHub Actions. The Go toolchain
is confined to the builder stage. No vendor reporting mechanism was identified
in the PostgreSQL runtime assembled here; `pg_stat_statements` remains enabled
and records local database statistics.

All repository Trivy entrypoints disable anonymous usage reporting with
`TRIVY_DISABLE_TELEMETRY=true` and announcement/version requests with
`TRIVY_SKIP_VERSION_CHECK=true`. Workflows using `trivy-action` receive these
settings through workflow environment variables; Docker invocations pass them
explicitly into the scanner container. The native local script exports both
settings before invoking Trivy. Scans use Trivy 0.75.0 by default.
Vulnerability database downloads, security checks, JSON reports, and the
HIGH/CRITICAL publication gate remain active. These opt-outs do not make
builds or scans network-free.

The Go opt-out applies to subsequent builds; existing runtime containers do not
contain the Go toolchain.

Every push to `master` starts `rebuild-on-push.yml`, which runs the daily
workflow with the same gates. The image records the commit of this repository it
was built from (`io.github.carvvf.pgsql-docker.repository.revision`), and both
workflows rebuild when the active image carries another commit, also when the
upstream version and runtime base are unchanged. Documentation-only commits are
included. Daily, manual and push-triggered runs of `scan-active-image.yml` are
serialized, so two of them never both rebuild the same commit: a run started
while another is in progress waits, and GitHub keeps only the most recent waiting
run. A waiting manual `force_rebuild` replaced this way must be requested again.
A `publish-custom.yml` run started directly is serialized only with other
publications. To rebuild without a new commit, request one manually:

```bash
gh workflow run scan-active-image.yml --repo carvvf/pgsql-docker -f force_rebuild=true
```

The workflow runs the existing build, scan, runtime-test, and publication gates.
After publication, follow the downstream update procedure above, retaining the
data volumes. The deliberate failure notification after a clean rebuild remains
part of that procedure.

## VS Code tasks

The workspace provides these tasks without requiring locally installed lint or
scanner binaries:

- `Docker: build local image` compiles `pgsql-custom:local` from the
  verified official PostgreSQL 18 release signal on Ubuntu 24.04.
- `Test: PostgreSQL runtime` builds the image and runs the Ragtime-compatible
  smoke test (prompts for a `ragtime-rag-orch` path, or leave it empty to use
  the vendored fixture).
- `Trivy: scan CVE` builds the image, runs a pinned Trivy container against
  the repository and local image, writes reports under `reports/trivy`, and
  fails on HIGH or CRITICAL findings.
- `Test: build inputs` checks release resolution, provenance, and major-version
  guards using simulated infrastructure.
- `Test: all` runs resolver regression tests, Dockerfile, shell, and workflow
  linting, and the runtime test in sequence. Run `Trivy: scan CVE` separately.

The first Trivy run downloads the vulnerability database into
`reports/trivy/cache`; later runs reuse it. Delete that directory to force a
fresh database download.

## Security scope and limitations

Rebuilding on Ubuntu can remediate fixable Ubuntu packages before an official
PostgreSQL image is refreshed. It does not make PostgreSQL or its upstream
dependencies safe by itself. The build also deliberately narrows PostgreSQL's
own feature set relative to the official image (ICU, LLVM JIT, libxml/libxslt,
LDAP, GSSAPI, PAM, systemd notify, PL/Perl, PL/Python, and PL/Tcl are all
disabled) because Ragtime's contract does not use them: each is one fewer
optional dependency this image has to carry, patch, and scan. A candidate
with unresolved HIGH or CRITICAL findings is not published.

## License and third-party components

This repository's own original content (the Dockerfile, CI workflows,
scripts, and documentation) has its own license; see `LICENSE`. That license
is separate from the licenses of what the image actually ships:

- PostgreSQL's own license (the PostgreSQL License), embedded at
  `/licenses/PostgreSQL-COPYRIGHT.txt`, copied from the resolved source
  revision at build time.
- `gosu`'s license (Apache-2.0), embedded at
  `/licenses/gosu-Apache-2.0.txt`, copied from its resolved source revision.
- The vendored `docker-library/postgres` entrypoint scripts' license (MIT),
  embedded at `/licenses/docker-library-postgres-MIT.txt`, copied from its
  resolved source revision.

The image also contains operating-system packages with their own licensing
and attribution requirements. BuildKit publishes an SBOM attestation for each
release; do not represent the complete container as exclusively covered by
this repository's own license without reviewing that SBOM.
