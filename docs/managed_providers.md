# Verifying a Managed Provider

This document describes how to verify Volvra on a managed PostgreSQL
service, and records what each provider requires. Volvra's design
exists for these services, so a claim that Volvra runs on one is worth
only as much as the verification behind it.

## Why this verification matters

Volvra installs as plain SQL, needs no superuser, and touches no server
filesystem, specifically so that it works where extensions cannot be
installed. Every constraint in the engine follows from that goal.

Testing in a container proves the code works; it does not prove the
constraint holds. Only a real service proves that, because only a real
service withholds the privileges a container gives away.

## Running the check

The `test/provider.sh` script runs the whole verification against a
connection string. The script needs `psql` and nothing else, and runs
from a workstation.

Keep the password out of the connection string. A password written
into a command line is recorded in the shell history and is visible to
anyone who can list processes on that machine. Set `PGPASSWORD`
instead, which `psql` reads, and which also avoids having to
percent-encode a password containing `@`, `/`, `:`, or `#`:

```bash
printf 'Database password: '; stty -echo; read -r PGPASSWORD; stty echo; echo
export PGPASSWORD
./test/provider.sh --dsn "postgres://master@cluster.rds.amazonaws.com:5432/probe"
```

Point the script at a throwaway database. The script installs Volvra
and drops the `volvra` schema when it finishes, which destroys history;
pass `--keep` to leave the installation in place. The script refuses to
run against a database whose `volvra.change_log` already holds rows.

The script checks the following, in the order that matters:

- the installing role is not a superuser, which is the property under
  test.
- the role holds CREATE on the database and CREATEROLE, and the three
  cluster-wide Volvra roles can be created.
- Volvra installs, and installs a second time as a no-op.
- the features providers most often restrict work: range partitioning,
  row-level security with a policy, and a statement-level TRUNCATE
  trigger.
- an undo round-trips real data, and the application-declared actor is
  recorded.
- `volvra.maintain`, `volvra.seal`, and `volvra.verify` all run.
- `volvra.preflight` reports nothing critical.
- whether the durable tier is available, and if not, exactly why.

The final block is the thing to report. A verification that passes
prints the server version, the role, and whether that role is a
superuser.

## Amazon Aurora PostgreSQL

Aurora gives the master user the `rds_superuser` role, which is not a
PostgreSQL superuser. That is the configuration Volvra is designed
for, and it is why `volvra.preflight` should report no critical
findings on Aurora: the critical findings concern a superuser-owned
install, which Aurora cannot produce.

If you need a cluster to verify against, `test/aurora-setup.md` in the
repository builds a throwaway Aurora Serverless v2 cluster with the AWS
command line, runs this verification, and deletes everything again.
Those are maintainer notes rather than product documentation, and the
teardown section is the important part: an Aurora cluster costs money
for as long as it exists.

Verify Aurora with the following steps.

1. Create a throwaway database on the cluster, so the verification
    cannot touch anything that matters:

    ```sql
    CREATE DATABASE volvra_probe;
    ```

2. Confirm the writer endpoint is reachable from where the script
    runs. Aurora accepts connections only from within the VPC unless
    the cluster is publicly accessible, so run the script from an EC2
    instance in the same VPC, or through a bastion or VPN.

3. Run the check against the **writer** endpoint. A reader endpoint
    cannot create objects, and cannot create a replication slot:

    ```bash
    ./test/provider.sh \
      --dsn "postgres://master@mycluster.cluster-abc.eu-west-1.rds.amazonaws.com:5432/volvra_probe?sslmode=require"
    ```

4. Read the section 9 output. The trigger tier does not need logical
    replication, so a skip there is not a failure. Continue to the
    next step only if you intend to run the companion.

5. For the durable tier, set `rds.logical_replication` to 1 in the DB
    **cluster** parameter group, not the instance parameter group. The
    setting is static, so the writer instance needs a reboot before
    the change takes effect.

6. Grant the replication role to the user the companion connects as.
    Aurora and RDS gate replication behind a role rather than the
    `REPLICATION` attribute:

    ```sql
    GRANT rds_replication TO master;
    ```

7. Re-run the check. Section 9 should now report that a `pgoutput`
    slot can be created, and `volvra.companion_setup` should report
    `wal_level` as ready.

An abandoned replication slot retains write-ahead log until the
storage fills, and on Aurora that storage is the cluster volume. Run
`volvra.companion_status` to see retained WAL against both thresholds,
and drop any slot left behind by a verification:

```sql
SELECT pg_drop_replication_slot('volvra_companion');
```

## Supabase

Supabase is the cheapest verification to run, and it tests the same
property Aurora does. The free plan needs no infrastructure, and the
`postgres` role it gives you is not a superuser: `supabase_admin` is
the only superuser on the instance, and the `postgres` role cannot
escalate to it. That is the configuration Volvra is designed for.

Verify Supabase with the following steps.

1. Create a project on the free plan. Note the database password
    shown at creation; it is not shown again.

2. Take the connection string from the project's connection settings,
    and choose the **direct connection**, not a pooled one. Volvra
    records an application-declared actor through a session setting,
    and a transaction-mode pooler hands the session to another client
    between transactions. The
    [Configuration](configuration.md) document covers what that does
    to attribution.

3. Run the verification against the database the project already
    provides. A Supabase project has one database, so there is no
    throwaway database to create; pass `--keep` if you want the
    installation to survive, and expect the script to drop the
    `volvra` schema otherwise:

    ```bash
    printf 'Database password: '; stty -echo; read -r PGPASSWORD; stty echo; echo
    export PGPASSWORD
    ./test/provider.sh --dsn "postgres://postgres@HOST:5432/postgres" --keep
    ```

4. Read section 9. Supabase runs `wal_level` as `logical` for its own
    realtime feature, so the durable tier may be available without any
    parameter change. Whether the `postgres` role may create its own
    replication slot is the part worth reporting either way.

A free project pauses after a week of inactivity and takes around
thirty seconds to wake. That does not affect a verification run in one
sitting, but a paused project refuses connections, which looks like a
network failure rather than a paused project.

## Neon

Neon, like Supabase, needs no infrastructure and has a free plan. The
default role `neondb_owner` holds membership in `neon_superuser`,
which carries CREATEDB, CREATEROLE, BYPASSRLS, and REPLICATION, but is
not a PostgreSQL superuser. That is the configuration Volvra is
designed for.

Two things about Neon are worth knowing before starting.

Enabling logical replication is **not reversible**. The setting
changes `wal_level` from `replica` to `logical` for every database in
the project, and restarts the computes, which drops active
connections. Verify the trigger tier first without it; the durable
tier is optional, and most deployments never use it.

A connected replication subscriber keeps the compute awake. Neon's
free plan suspends a compute after five minutes of inactivity, and a
consumed slot prevents that, so a slot left behind after a
verification bills compute time continuously. An unconsumed slot is
also not free: it retains write-ahead log until it is dropped.

Verify Neon with the following steps.

1. Create a project on the free plan and copy the connection string
    from the dashboard. Neon requires TLS, and the connection string
    it gives you already includes `sslmode=require`.

2. Run the verification against the database the project provides,
    without enabling logical replication:

    ```bash
    printf 'Database password: '; stty -echo; read -r PGPASSWORD; stty echo; echo
    export PGPASSWORD
    ./test/provider.sh --keep \
      --dsn "postgres://neondb_owner@HOST/neondb?sslmode=require"
    ```

    Use the **direct** endpoint, not the pooled one. Neon's dashboard
    offers a pooler host by default, and its pooler runs in
    transaction mode, which breaks the session setting Volvra reads
    the actor from and cannot create a replication slot. The direct
    host is the same name with `-pooler` removed.

    Section 9 reports that `wal_level` is `replica` and skips the
    durable tier. That is the expected result, and not a failure.

3. Stop here unless you want the durable tier verified. If you do,
    enable logical replication in the Neon console, accept that the
    change cannot be undone for that project, and re-run the same
    command. Section 9 should then create and drop a `pgoutput` slot.

4. Confirm no slot survived the run, because one left behind keeps the
    compute awake and retains WAL:

    ```sql
    SELECT slot_name, active FROM pg_replication_slots;
    ```

Roles created from SQL on Neon, which is how `test/provider.sh`
creates the three Volvra roles, do not inherit `neon_superuser`. They
are ordinary roles, which is what Volvra wants them to be.

One difference from other providers is worth recording rather than
hiding: `neondb_owner` holds BYPASSRLS, so the row-level security
policy on the history does not constrain that role. The verification
still passes, because it asserts that the policy exists rather than
that the owner is subject to it, and a table owner bypasses row-level
security on most providers regardless. It means the history's read
restriction on Neon protects other roles, not `neondb_owner`.

## pgEdge Cloud

pgEdge Cloud is the first verified service that gives an application
role rather than an administrative one, and the difference is worth
understanding before installing.

The `app` role a database is created with holds CREATE on the database
but not CREATEROLE. Volvra installs and works with it: capture, undo,
TRUNCATE capture, maintenance, sealing, and verification all pass. What
fails is the creation of the three cluster-wide Volvra roles, and
`volvra.preflight` reports their absence as critical, because without
them every privilege check degrades to permissive.

Install as the `admin` role, which holds CREATEROLE, or have an
administrator create the three roles once:

```sql
CREATE ROLE volvra_viewer NOLOGIN;
CREATE ROLE volvra_operator NOLOGIN;
CREATE ROLE volvra_admin NOLOGIN;
GRANT volvra_viewer TO volvra_operator;
GRANT volvra_operator TO volvra_admin;
```

The durable tier needs one more grant. `wal_level` is already
`logical`, but neither role carries the REPLICATION attribute, so
creating a slot fails with `permission denied to use replication
slots`. An administrator grants it:

```sql
ALTER ROLE admin REPLICATION;
```

### Distributed clusters

One question is open and matters only on a multi-node pgEdge cluster:
whether Volvra should capture changes that arrive through replication,
or only changes written locally.

PostgreSQL does not fire an ordinary `AFTER` trigger for rows applied
by logical replication; a trigger has to be created `ENABLE ALWAYS` for
that. Volvra creates ordinary triggers, so on a multi-master cluster
each node would record the changes written to that node and not those
replicated from its peers. History would be per node, and an undo on
one node would neither see nor revert a change made on another.

Whether that is right depends on what an undo should mean across
nodes, and the answer is not obvious: capturing replicated changes as
well would record every change on every node, which is complete but
duplicated, and undoing on one node would then replicate the undo to
the others. Establish the intended behaviour before covering tables on
a distributed cluster. The verification in this document runs on one
connection and cannot detect the difference, so a pass says nothing
either way.

## What to record

Report a verification with the service, the engine version, the result
block, and any check that failed. A verification is specific to a
major version and a service, so Aurora PostgreSQL 16 passing says
nothing about Aurora PostgreSQL 14.

The following table tracks what has been verified. Every row is
unverified until someone runs the script and records the result:

| Service | Engine version | Trigger tier | Durable tier | Verified |
|---|---|---|---|---|
| Supabase | PostgreSQL 17.6 | Passed | Passed end to end | 2026-09-11 |
| Neon | PostgreSQL 18.6 | Passed | Passed end to end | 2026-09-11 |
| pgEdge Cloud | PostgreSQL 16.15 | Passed | Needs a grant | 2026-09-11 |
| Amazon Aurora PostgreSQL | - | Not yet run | Not yet run | - |
| Amazon RDS for PostgreSQL | - | Not yet run | Not yet run | - |
| Google Cloud SQL | - | Not yet run | Not yet run | - |

The durable tier column distinguishes two things, because
`test/provider.sh` alone cannot tell them apart. "Preconditions met"
means `wal_level` is logical, a `pgoutput` slot can be created, and
`volvra.companion_setup` reports ready. "Passed end to end" means the
companion was actually run against that service: it streamed changes
into an archive, the archive verified, the in-database history was
then purged entirely, the archive was restored over it, and an undo
driven only by that restored history put the data back. That is the
claim the durable tier exists to make, and only the second form
establishes it.

Do not describe a service as supported before its row is filled in.
For the services still marked "Not yet run", the documentation's claim
rests on the design requiring nothing they withhold, which is a
reasoned expectation rather than a tested fact.

The Neon run passed all 22 trigger-tier checks on PostgreSQL 18.6,
against `neondb_owner`, on the free plan. Roles created from SQL on
Neon do not inherit `neon_superuser`, and the three Volvra roles
worked correctly as ordinary roles.

The durable tier was then verified end to end on Neon, after enabling
logical replication for the project. The companion created its slot,
streamed three changes into an archive of one segment, and that
archive verified with its chain intact. `volvra.purge` then removed
every row of in-database history, the archive was restored over the
empty history, and an undo driven entirely by the restored changes put
both altered rows back to their original values. The history survived
the loss of the database's own copy of it, which is the whole purpose
of the durable tier and the first time it has been demonstrated
against a managed service rather than a container.

Two operational notes from that run. Use `--segment-bytes` smaller
than the 64 MB default for a short test, because a segment reaches the
manifest only when it rotates, and a clean shutdown is what rotates
the last one. Drop the slot afterwards: on Neon a consumed slot keeps
the compute awake and defeats scale to zero, and an unconsumed slot
retains write-ahead log.

Together the two verified services cover PostgreSQL 17 and 18 on two
different platforms, which is the more useful pair than two runs on
one version.

The durable tier is verified end to end on Supabase as well. The
companion streamed three changes into an archive of two segments, the
archive verified, `volvra.purge` emptied the in-database history, the
archive was restored over it, and an undo driven only by restored
history put both altered rows back. Supabase needs no parameter change
for this: `wal_level` is already `logical` for its realtime feature,
and the `postgres` role may create its own slot.

Drop the slot when a verification finishes. The free plan gives 500 MB
of database storage in total, and an abandoned slot retains
write-ahead log until it is dropped.

The Supabase run passed all 24 checks with nothing skipped, on the
free plan, against the `postgres` role that Supabase provides. Two
results there were not predictable in advance and are the reason the
verification exists: that role holds CREATEROLE, so the three
cluster-wide Volvra roles can be created; and it may create its own
`pgoutput` replication slot, so the durable tier works without a
paid plan or a parameter change. Supabase runs `wal_level` as
`logical` already, for its own realtime feature.

## Next Steps

- The [Installation](installation.md) document describes the install
  itself and the privileges it needs.
- The [Companion Overview](companion.md) document explains the durable
  tier and its two additional requirements.
- The [Troubleshooting](troubleshooting.md) document covers what to do
  when a check fails.
