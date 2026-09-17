# AGENTS.md

## Purpose and scope

This repository builds and publishes a custom, hardened PostgreSQL container
image from the upstream PostgreSQL source release corresponding to the
`postgres:18` Docker Hub tag. Its final runtime base is `ubuntu:24.04`, and it
is published to GitHub Container Registry (GHCR) for `linux/amd64`.

The primary purpose is to reduce the exposure window when the official
`postgres` image (Debian- or Alpine-based, maintained by `docker-library`, not
by the PostgreSQL project) contains fixable operating-system vulnerabilities
that have not yet been addressed upstream. Daily GitHub Actions workflows
build a candidate with current operating-system packages, scan it, and
publish it only when it meets the configured security policy.

This is **not** a fork of the PostgreSQL source repository. Source is fetched
at the version and immutable revision resolved by CI; do not introduce a
tracked PostgreSQL source checkout, upstream-alignment branch, or
source-fork assumption.

## Language policy

- Chat and discussion with the user: Italian.
- Repository content: English only, including code, comments, documentation,
  configuration, workflow summaries, operator-facing errors, test names, and
  suggested commit messages.

Translate Italian requirements before writing repository content. Before
finalizing a change, check that no Italian text was introduced outside
fixtures or test data where it is the subject of the test.

## Image and downstream compatibility contract

The image replaces the `postgres` service used by
`../ragtime-rag-orch/docker/services/docker-compose.yml`. Compatibility with
that deployment, with its init bootstrap script
(`../ragtime-rag-orch/docker/services/postgres-init/10-ragtime-bootstrap.sh`),
and with its AppArmor profile
(`../ragtime-rag-orch/security/apparmor/docker-postgres`) is mandatory.

Unless a coordinated downstream change has been requested and validated, keep
the upstream `docker-library/postgres` runtime contract unchanged:

- Configuration through `POSTGRES_USER`, `POSTGRES_PASSWORD`, `POSTGRES_DB`,
  and `POSTGRES_INITDB_ARGS` environment variables, processed on first run
  exactly like the official image (first-run detection on an empty `PGDATA`,
  then never again).
- Automatic execution, on first initialization only, of every `*.sh`, `*.sql`,
  and `*.sql.gz` file mounted at `/docker-entrypoint-initdb.d`, in
  lexical order, aborting the container start on any script failure.
- `PGDATA`-resident configuration (`postgresql.conf`, `pg_hba.conf`,
  `pg_ident.conf` written inside the data directory by `initdb`). Do not adopt
  the Debian package layout (`/etc/postgresql/<version>/...`,
  `pg_ctlcluster`, multi-cluster tooling): the downstream AppArmor profile
  denies writes to `/etc/**`, so configuration cannot live there.
- The container starts as root, repairs ownership/permissions on a persisted
  data volume, then drops privileges to a dedicated, stable `postgres`
  uid/gid via `gosu` before executing the `postgres` server process. The
  image must ship a `gosu` binary on `PATH`: Ragtime's Compose healthcheck
  invokes `gosu postgres psql ...` directly, and its AppArmor profile grants
  exactly the capability set this sequence needs
  (`CHOWN`, `DAC_OVERRIDE`, `FOWNER`, `SETGID`, `SETUID`) and nothing else.
  Do not switch to a non-root entry user, remove `gosu`, or change the
  bootstrap uid/gid without a coordinated change to that AppArmor profile and
  the Compose healthcheck.
- Writable runtime paths limited to `/var/lib/postgresql/**`,
  `/var/run/postgresql/**`, `/run/postgresql/**`, `/dev/shm/**`, and
  `/tmp/**`. Do not require write access anywhere else at runtime (no writes
  under `/usr`, `/etc`, `/bin`, `/lib`, `/opt`, `/root`, `/sbin`, `/srv`,
  `/var/cache`, `/var/log`, `/var/spool`): the downstream AppArmor profile
  denies it.
- SSL/TLS support compiled in (OpenSSL). The AppArmor profile grants read
  access to `/etc/ragtime/tls/**` for a TLS transport overlay; do not build
  PostgreSQL with `--without-openssl` or drop libssl from the runtime image.
- Support for `initdb --locale-provider=builtin --builtin-locale=C.UTF-8`
  (the builtin C.UTF-8 collation provider, PostgreSQL 17+). Ragtime pins
  collation this way specifically to avoid collation-version drift tied to
  the operating system's glibc or ICU packages. Preserve builtin-provider
  support; do not build in a way that silently falls back to a libc/ICU
  collation for this locale.
- `pg_stat_statements` available for `shared_preload_libraries`. This is a
  PostgreSQL contrib module built from the same source tree; no external
  extension dependency is required for the current contract.
- Port `5432`.

Ragtime runs PostgreSQL with `cap_drop: ALL` plus the narrow bootstrap
capability set above, an AppArmor profile, `no-new-privileges`, noexec tmpfs
mounts for `/tmp` and `/var/run/postgresql`, and named volumes for
`postgres_data`. Do not change the working directory, entry user/privilege-drop
sequence, capability requirements, writable paths, or extension surface
without changing and validating Ragtime's Compose file, bootstrap script, and
AppArmor profile in the same coordinated work.

Do not add runtime packages merely to implement a health check. Ragtime's
healthcheck already relies only on `gosu` and `psql`, both required by the
contract above for other reasons.

pgvector or other extensions are not currently part of the Ragtime contract
(the vector store is a separate Qdrant service). Do not add extensions
speculatively; if a future requirement needs one, treat it as a coordinated,
explicitly requested change, not a default.

## Version and upgrade policy

PostgreSQL's on-disk format is compatible within a major version but not
across major versions: unlike Qdrant, a mutable `latest` tag must never
silently cross a major-version boundary, because doing so against an existing
data volume breaks the running database without an explicit `pg_upgrade` (or
dump/restore) step.

- Track the official `postgres:18` tag as the version-parity signal, the same
  way `qdrant-docker` tracks `qdrant/qdrant:latest` — to resolve the current
  upstream minor version and its manifest digest, not to reuse its layers.
- Automatic daily rebuilds apply only within the pinned major version: a new
  PostgreSQL 18 minor release, or a changed Ubuntu runtime-base digest, or
  HIGH/CRITICAL findings in the active image.
- A PostgreSQL major-version bump (for example 18 to 19) is never automatic.
  It requires an explicit, user-authorized change to the pinned major
  version, and must ship with operator guidance for running `pg_upgrade` (or
  an equivalent dump/restore) against Ragtime's `postgres_data` volume before
  the new image is deployed.

## Security and update policy

- Resolve the official PostgreSQL minor version and the official image's
  manifest digest during CI (from `postgres:18`), then resolve and verify the
  matching upstream PostgreSQL source tag and commit. Record all immutable
  identifiers in OCI labels and workflow output.
- Resolve and pin an immutable commit for `gosu` (tianon/gosu) source, built
  from source in the same image, verified the same way as the PostgreSQL
  source. This is a second upstream source the release process must track,
  distinct from the PostgreSQL release itself.
- Use `ubuntu:24.04` as the final runtime base and resolve its manifest digest
  during CI. Keep the Dockerfile small, avoid unnecessary runtime packages,
  clean package metadata, and do not embed credentials.
- Force the runtime `apt-get update/upgrade/install` layer to actually re-run
  on every CI build, even when the PostgreSQL source revision and the Ubuntu
  base digest are both unchanged from the previous build. Do this with a
  build arg tied to a per-run value (for example `CACHEBUST=<GitHub run ID>`)
  consumed just before that `RUN` instruction. Without this, Docker/GHA layer
  caching reuses the previous apt layer unchanged, and the rebuild silently
  stops picking up new OS security patches — defeating the daily-rebuild
  security model, since apt mirrors publish patches far more often than the
  `ubuntu:24.04` tag digest changes. (`qdrant-docker` shipped without this at
  first and had to add it back; carry the fix forward from the start here.)
- A source rebuild can remediate fixable Ubuntu CVEs and upstream PostgreSQL
  dependencies only when their respective upstream releases contain a fix. It
  does not remediate findings without an available fix. Never conceal such
  findings or publish a candidate that violates the security policy.
- Scan image vulnerabilities with Trivy. HIGH and CRITICAL findings are the
  default publication gate for OS and library vulnerabilities unless the user
  explicitly changes that policy.
- Produce and retain JSON scan reports as GitHub Actions artifacts. A report
  is evidence, not a reason to weaken the gate.
- Use immutable release tags in the form
  `<postgres-version>-custom.<N>` and update the mutable `latest` tag only
  after the candidate has passed build, scan, and runtime checks, and only
  within the pinned major version (see "Version and upgrade policy").
- The daily workflow intentionally fails after a successful rebuild and final
  scan to notify downstream operators that they must pull and redeploy the
  new `latest` image. Preserve this behavior unless the user requests another
  notification mechanism.
- Serialize scan/publish runs with a shared GitHub Actions concurrency group.
  This prevents competing runs from racing on `latest` or the custom sequence
  number.

## CI expectations

Use the workflow structure in `../qdrant-docker` and `../unoserver-docker` as
a reference, adapting resolution, build, and test steps to PostgreSQL rather
than copying Qdrant- or Unoserver-specific logic.

The expected checks are:

1. Resolve the official PostgreSQL minor version and source tag/commit, the
   official `postgres:18` image digest, the Ubuntu runtime-base digest, and
   the pinned `gosu` source commit.
2. Scan the active GHCR `latest` image and retain the report.
3. Build a custom candidate when the PostgreSQL source revision or Ubuntu
   runtime digest has changed, the active image has findings, or a manual
   workflow explicitly requests a rebuild.
4. Build and scan the `linux/amd64` candidate with Trivy. Scope the scan with
   `scanners: vuln` and `severity: HIGH,CRITICAL`. If the image bakes in an
   SBOM or other dependency-manifest file (for example an SPDX/CycloneDX
   document listing build-time or upstream-project dependencies that are not
   themselves present or executed in the runtime image), exclude it with
   `skip-files`, or Trivy's language-package scanners can misread it as
   installed packages and produce findings that block publication for
   dependencies that were never actually shipped. `qdrant-docker` hit exactly
   this with its bundled `cargo-sbom` and web-UI build-manifest output; check
   for the same risk here before adding any SBOM file to the image.
5. Start the `linux/amd64` candidate using constraints equivalent to the
   Ragtime Compose service (capability set, AppArmor profile, tmpfs mounts,
   resource limits), run the Ragtime bootstrap init flow (or an equivalent
   owner/app-role smoke script) against `POSTGRES_INITDB_ARGS`, confirm
   `pg_stat_statements` loads, confirm the `gosu postgres psql ... select 1`
   healthcheck command succeeds, then verify persistence across a restart
   using the `postgres_data` volume.
6. Publish the versioned tag and `latest` only after every required check
   passes; inspect the published manifest to confirm `linux/amd64`. If the
   publish step sets `provenance: mode=max` and/or `sbom: true`, buildx
   attaches a non-platform attestation manifest to the same OCI index. Filter
   by platform before asserting a single match, for example
   `[.manifests[] | select(.platform.os == "linux" and .platform.architecture
   == "amd64")] | length == 1` — an unfiltered `.manifests | length == 1`
   check breaks the moment that attestation manifest is added.
   `qdrant-docker` shipped the unfiltered version first and had to fix it;
   start with the filtered form here.
7. Re-scan the published mutable `latest` tag and intentionally signal the
   downstream-update notification only when a rebuilt image is clean.

Local developer tooling may provide filesystem, Dockerfile configuration, and
image scans. Keep generated reports out of image build contexts and version
control unless the user explicitly requests otherwise.

Use `hadolint` for Dockerfiles and `shellcheck` for shell scripts when those
files are introduced or changed. Consider SBOM generation, provenance, and
keyless signing when their operational ownership is defined; do not add
signing requirements that would prevent emergency vulnerability remediation.

## Licensing and documentation

This repository's own original content (Dockerfile, CI workflows, scripts,
documentation) has its own license (`LICENSE`), scoped to that original
content only. It is separate from, and must not be conflated with, the
licenses of anything compiled or vendored into the image:

- PostgreSQL's own license (the PostgreSQL License, a permissive
  MIT-style license) covers PostgreSQL itself. If the image ships a copy of
  it, copy it from the resolved PostgreSQL source tree at build time (a
  `COPY --from=<build stage>` of the file the checked-out source actually
  contains), not a static copy committed to this repository — the text must
  track whatever revision CI actually resolved and built, not a snapshot
  taken once by hand.
- `gosu` has its own license (MIT, tianon/gosu) and needs the same treatment
  if its binary is vendored into the image: copy its license text from its
  own resolved source revision, do not hand-copy it once and let it drift.
- `qdrant-docker` originally shipped a single `LICENSE` file with the
  upstream project's copyright holder in it, conflating its own repository
  license with Qdrant's — this was wrong and had to be fixed (commit
  `26f1e26`). Do not reproduce that mistake here: check which license text is
  being attributed to whom before committing a `LICENSE` file or a `COPY`
  instruction that embeds one.

Document any AI assistance used to write repository documentation (a note at
the top of `README.md`, matching the convention `qdrant-docker` adopted),
since these documents may otherwise read as fully human-authored and
unverified claims in them should be checked against the actual source before
being trusted.

## Downstream delivery and operations

The GHCR package must either be public or the Ragtime hosts must receive and
manage pull credentials. Do not silently turn a public Docker Hub dependency
into an inaccessible private GHCR dependency.

The downstream update procedure, for a minor-version or OS-patch update
within the same pinned PostgreSQL major version, is:

```bash
docker compose pull postgres
docker compose up -d postgres
```

The existing `postgres_data` named volume must be retained. Do not recommend
`docker compose down -v` for an image update because it deletes PostgreSQL
data.

A PostgreSQL major-version update is a separate, explicit operation and must
never be performed with a routine `pull`/`up -d`: it requires `pg_upgrade` (or
dump/restore) against `postgres_data` before the new image can start
correctly. State this distinction whenever recommending an update.

For development, `latest` is acceptable. For controlled production rollouts,
prefer an explicit immutable `-custom.N` tag so rollback and provenance are
unambiguous.

## Working principles

- Prefer small, additive, clearly documented changes.
- Explain security, runtime, and downstream operational impact whenever a
  change affects them.
- Do not disable, suppress, or downgrade security checks to make a workflow
  pass. State the root cause and whether a finding is fixable.
- Do not add extensions, change the PostgreSQL role/database bootstrap
  behavior, or alter the Ragtime deployment as a side effect of image
  hardening.
- Do not change the entry-user/privilege-drop sequence, the capability set,
  the writable-path surface, or the collation/locale provider without
  coordinating the matching change in Ragtime's Compose file, bootstrap
  script, and AppArmor profile in the same piece of work.
- Before commits or remote changes, inspect the working tree and current
  branch. Use a dedicated feature branch and obtain explicit user
  authorization before committing, pushing, merging, or changing remote
  state.

## Deliverables

For each meaningful change, report:

1. What changed.
2. Why it supports the image's security and update goal.
3. How to validate it locally or in GitHub Actions.
4. Downstream compatibility and rollout implications.
5. Any remaining vulnerabilities, limitations, or required operator action.
