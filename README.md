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
manifest digest. It rebuilds when any of these change, scans the candidate
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

Build PostgreSQL 18.6 from source on Ubuntu 24.04:

```bash
docker build --pull --no-cache -t pgsql-custom:local .
```

CI additionally resolves the immutable commit for the PostgreSQL source tag,
the `gosu` source tag, and the `docker-library/postgres` entrypoint commit,
and fails the build when any checked-out source does not match what was
resolved. OCI labels record all three source revisions, the official-image
digest used as a release signal, and the Ubuntu runtime-base digest.

Run the compatibility smoke test. It applies the relevant Ragtime container
restrictions, runs the real Ragtime bootstrap init flow (vendored as a test
fixture; see `tests/fixtures/postgres-init`), confirms `pg_stat_statements`
and the builtin locale provider, restarts the container, verifies
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

For a local Trivy filesystem, Dockerfile, and image scan, install Trivy and
run:

```bash
IMAGE_REF=pgsql-custom:local scripts/trivy/scan-image.sh
```

## VS Code tasks

The workspace provides these tasks without requiring locally installed lint or
scanner binaries:

- `Docker: build local image` compiles `pgsql-custom:local` from the default
  PostgreSQL source release on Ubuntu 24.04.
- `Test: PostgreSQL runtime` builds the image and runs the Ragtime-compatible
  smoke test (prompts for a `ragtime-rag-orch` path, or leave it empty to use
  the vendored fixture).
- `Trivy: scan CVE` builds the image, runs a pinned Trivy container against
  the repository and local image, writes reports under `reports/trivy`, and
  fails on HIGH or CRITICAL findings.
- `Test: all` runs Dockerfile, shell, and workflow linting and the runtime
  test in sequence. Run `Trivy: scan CVE` separately.

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
