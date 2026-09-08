# Developer Resources

This document describes how to build, test, and contribute to Volvra.
Contributions are welcome.

## Repository layout

The following table describes the top-level directories:

| Path | Contents |
|---|---|
| sql/volvra.sql | The whole engine, as one installable SQL file. |
| bin/volvra | The command line script, written in shell over psql. |
| companion/ | The durable tier, written in Go. |
| extension/ | Optional CREATE EXTENSION packaging, generated. |
| test/ | Test suites and their runners. |
| tools/ | Release helpers. |
| docs/ | This documentation. |

## Building the companion

The companion needs the Go toolchain, version 1.25 or later, which
is the floor its dependencies declare:

```bash
cd companion
go vet ./...
go build -o volvra-companion .
```

## Running the test suites

The main suite runs every phase against a throwaway container for each
supported PostgreSQL version:

```bash
./test/run.sh              # 14 15 16 17 18 19
./test/run.sh 17           # one version
```

Each version runs the following phases in order:

1. Volvra installs as a non-superuser role on a pristine cluster,
   which proves the managed-provider privilege model.
2. Volvra installs twice, which proves the install is idempotent.
3. The acceptance suite exercises the documented workflow.
4. The security suite attacks the privilege model as real
   unprivileged roles.
5. The correctness suite covers conflicts, truncates, schema drift,
   and type fidelity.
6. The scope suite covers transaction, predicate, and actor selection.
7. The scale suite covers partitioning, retention, and observability.
8. The trust suite attacks sealing, erasure, and column exclusion.
9. The command line suite exercises every command.
10. The upgrade suite installs the previous schema, seeds history, and
    upgrades.

Per-version logs land in `test/logs/`.

## Running the companion suite

The companion suite runs separately, because the suite needs a server
started with `wal_level=logical`, a published port, and a Go build on
the host:

```bash
./test/run-companion.sh    # 14 15 16 17 18 19
./test/companion.sh 17 55432
```

The decisive test destroys the in-database history entirely, restores
the archive, and then reverts the damage from archived history alone.

## Benchmarking

The benchmark measures throughput, disk, and write-ahead log volume
with and without coverage:

```bash
./test/bench.sh 17 20 3
```

The arguments are the PostgreSQL version, the seconds per run, and the
number of repetitions. The benchmark rebuilds the fixture and
re-establishes coverage for every repetition, and reports the best
result, because interference only ever costs throughput.

Do not compare figures across separate invocations. Throughput drifts
by about ten percent between runs, so the benchmark measures each
configuration side by side within one run.

## Building the extension packaging

The extension script is generated from `sql/volvra.sql`, so the two
cannot diverge:

```bash
cd extension
./build.sh
./test.sh 17
```

The build removes stale generated scripts, because an old script still
installs.

## Continuous integration

The GitHub Actions workflow runs the main suite, the companion suite,
and the extension packaging, with one job per PostgreSQL version and
`fail-fast` disabled so one version cannot hide the others.

## Testing conventions

Every check is a PL/pgSQL `ASSERT` with a message that states what
should have been true. Suites run under `ON_ERROR_STOP`, so the first
failure stops the run and names the assertion.

Negative tests wrap the operation in an exception handler and assert
both that the operation failed and that the operation failed for the
right reason.

## Release helpers

The following command prints the values a release should publish:

```bash
./tools/checksums.sh
```

Volvra installs as a file rather than a signed package, so a release
must publish a checksum, and ideally a signature, for the installer to
verify.

## Building the documentation

The documentation builds with MkDocs and the Material theme. Install
the pinned dependencies and serve the site locally:

```bash
pip install -r requirements.txt
mkdocs serve
```

The pins in `requirements.txt` match the primary pgEdge documentation
site, because that is the environment this project's `docs` directory
is built in when the site imports the directory. The pins also hold
MkDocs at 1.x on purpose: the Material team reports that MkDocs 2.0
removes the plugin system and rewrites theming, with no migration
path, and this project uses a theme override for its logo.

Confirm the site builds with no warnings before committing
documentation changes:

```bash
mkdocs build --strict
```

The `mkdocs.yml` and `docs` directory are self-contained and valid on
their own, which the primary site requires. Do not add configuration
that only works in the primary site context, such as redirects,
analytics, or a consent banner.

## Design decisions

The `DECISIONS.md` file in the repository root records the vocabulary
and design decisions that have already been argued, including what
each choice beat and why the alternative lost. Read the file before
renaming anything.

## Contributing

We welcome your project contributions. Open an issue to discuss a
change before starting substantial work.

For more information, visit
[docs.pgedge.com](https://docs.pgedge.com).
