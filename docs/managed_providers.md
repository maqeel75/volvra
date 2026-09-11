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
from a workstation:

```bash
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
    ./test/provider.sh --dsn "postgres://postgres:PASSWORD@HOST:5432/postgres"
    ```

4. Read section 9. Supabase runs `wal_level` as `logical` for its own
    realtime feature, so the durable tier may be available without any
    parameter change. Whether the `postgres` role may create its own
    replication slot is the part worth reporting either way.

A free project pauses after a week of inactivity and takes around
thirty seconds to wake. That does not affect a verification run in one
sitting, but a paused project refuses connections, which looks like a
network failure rather than a paused project.

## What to record

Report a verification with the service, the engine version, the result
block, and any check that failed. A verification is specific to a
major version and a service, so Aurora PostgreSQL 16 passing says
nothing about Aurora PostgreSQL 14.

The following table tracks what has been verified. Every row is
unverified until someone runs the script and records the result:

| Service | Engine version | Trigger tier | Durable tier | Verified |
|---|---|---|---|---|
| Supabase | PostgreSQL 17.6 | Passed | Passed | 2026-09-11 |
| Amazon Aurora PostgreSQL | - | Not yet run | Not yet run | - |
| Amazon RDS for PostgreSQL | - | Not yet run | Not yet run | - |
| Google Cloud SQL | - | Not yet run | Not yet run | - |
| Neon | - | Not yet run | Not yet run | - |

Do not describe a service as supported before its row is filled in.
For the services still marked "Not yet run", the documentation's claim
rests on the design requiring nothing they withhold, which is a
reasoned expectation rather than a tested fact.

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
