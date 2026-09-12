# Creating an Aurora cluster to verify pgVolvra against

Maintainer notes, not product documentation. This builds a throwaway
Aurora PostgreSQL cluster, runs `test/provider.sh` against it, and
deletes everything again.

Aurora costs money for as long as it exists. The teardown section at
the end is the important part of this file: an Aurora Serverless v2
cluster left running is a monthly bill for nothing. Check current
pricing for your region before starting; the shape of it is a few cents
per hour at the 0.5 ACU floor, and roughly tens of dollars a month if
forgotten.

Every command below is copy-paste. Run them one at a time and read each
result: a failure half way through leaves resources behind that the
teardown still has to remove.

## Console or command line

The command-line path is sections 0 to 7 below. The console path is
"Creating the cluster in the console", after them. Both produce the
same cluster; the console names a few things differently and creates
the subnet group for you.

Console labels move between AWS releases. The settings named below are
what matters; if a label has been reworded, look for the setting rather
than the exact phrase.

## 0. Prerequisites

The AWS CLI v2, `psql`, and credentials with permission to create RDS
clusters, DB subnet groups, parameter groups, and security groups.

```bash
aws --version
aws sts get-caller-identity
```

Set the values this runbook uses. Pick a region you do not mind
creating resources in, and a password with no `/`, `"`, `@`, or space:

```bash
export AWS_REGION=eu-west-1
export CL=volvra-probe                       # cluster identifier
export MASTER=volvra_master

# Prompted, not written down: a password in a command line is kept in
# the shell history and is visible to anyone who can list processes.
printf 'New master password: '; stty -echo; read -r PGPASSWORD; stty echo; echo
export PGPASSWORD
```

## 1. Choose an engine version

Do not guess a version; ask what the region offers and take the newest:

```bash
aws rds describe-db-engine-versions \
  --engine aurora-postgresql \
  --query 'DBEngineVersions[].EngineVersion' --output text | tr '\t' '\n' | sort -V | tail -5
```

Set the version and its parameter-group family. The family is
`aurora-postgresql` followed by the major version:

```bash
export EV=16.6                               # from the list above
export FAMILY=aurora-postgresql16
```

## 2. Networking

Aurora needs a DB subnet group covering at least two availability
zones. The default VPC already has one subnet per AZ:

```bash
export VPC=$(aws ec2 describe-vpcs --filters Name=isDefault,Values=true \
               --query 'Vpcs[0].VpcId' --output text)
echo "VPC: $VPC"

export SUBNETS=$(aws ec2 describe-subnets --filters Name=vpc-id,Values=$VPC \
                   --query 'Subnets[].SubnetId' --output text)
echo "subnets: $SUBNETS"

aws rds create-db-subnet-group \
  --db-subnet-group-name ${CL}-subnets \
  --db-subnet-group-description "volvra verification" \
  --subnet-ids $SUBNETS
```

Create a security group that admits only your own address on 5432.
This is a throwaway cluster reachable from the internet, so the
address restriction is the only thing protecting it. Do not widen it
to `0.0.0.0/0`:

```bash
export SG=$(aws ec2 create-security-group \
  --group-name ${CL}-sg --description "volvra verification" \
  --vpc-id $VPC --query 'GroupId' --output text)
echo "security group: $SG"

export MYIP=$(curl -s https://checkip.amazonaws.com)
aws ec2 authorize-security-group-ingress --group-id $SG \
  --protocol tcp --port 5432 --cidr ${MYIP}/32
echo "allowed from ${MYIP}/32"
```

If your account has no default VPC, or policy forbids a publicly
reachable database, create the cluster without
`--publicly-accessible` and run `test/provider.sh` from an EC2
instance in the same VPC instead. The script only needs `psql`.

## 3. Parameter group with logical replication enabled

`rds.logical_replication` is a static **cluster-level** parameter.
Setting it in the parameter group before the cluster exists avoids a
reboot later, and lets one pass verify both tiers:

```bash
aws rds create-db-cluster-parameter-group \
  --db-cluster-parameter-group-name ${CL}-params \
  --db-parameter-group-family $FAMILY \
  --description "volvra verification"

aws rds modify-db-cluster-parameter-group \
  --db-cluster-parameter-group-name ${CL}-params \
  --parameters "ParameterName=rds.logical_replication,ParameterValue=1,ApplyMethod=pending-reboot"
```

## 4. Create the cluster and one Serverless v2 instance

```bash
aws rds create-db-cluster \
  --db-cluster-identifier $CL \
  --engine aurora-postgresql --engine-version $EV \
  --master-username $MASTER --master-user-password "$PGPASSWORD" \
  --db-subnet-group-name ${CL}-subnets \
  --vpc-security-group-ids $SG \
  --db-cluster-parameter-group-name ${CL}-params \
  --serverless-v2-scaling-configuration MinCapacity=0.5,MaxCapacity=2 \
  --no-deletion-protection

aws rds create-db-instance \
  --db-instance-identifier ${CL}-1 \
  --db-cluster-identifier $CL \
  --engine aurora-postgresql \
  --db-instance-class db.serverless \
  --publicly-accessible
```

Wait for it. This takes several minutes:

```bash
aws rds wait db-instance-available --db-instance-identifier ${CL}-1
export PGHOST=$(aws rds describe-db-clusters --db-cluster-identifier $CL \
                  --query 'DBClusters[0].Endpoint' --output text)
echo "writer endpoint: $PGHOST"
```

Confirm you are connected to Aurora, and that the master user is not a
superuser:

```bash
psql "postgres://${MASTER}@${PGHOST}:5432/postgres?sslmode=require" \
  -c "SELECT version()" \
  -c "SELECT current_user, rolsuper FROM pg_roles WHERE rolname = current_user"
```

`rolsuper` must be `f`. If it is `t`, something is wrong: Aurora does
not grant superuser, and a superuser install is not what pgVolvra is
being verified against.

## 5. Prepare the database

```bash
psql "postgres://${MASTER}@${PGHOST}:5432/postgres?sslmode=require" \
  -c "CREATE DATABASE volvra_probe" \
  -c "GRANT rds_replication TO ${MASTER}"
```

`rds_replication` is how Aurora and RDS gate replication slots; the
`REPLICATION` role attribute is not available to you.

## 6. Run the verification

```bash
cd /path/to/volvra
./test/provider.sh \
  --dsn "postgres://${MASTER}@${PGHOST}:5432/volvra_probe?sslmode=require"
```

Read the result block at the end. Expect:

- `the installing role is not a superuser` to pass, which is the whole
  point of the exercise.
- `no critical findings` to pass. Both critical findings in
  `volvra.preflight` concern a superuser-owned install, which Aurora
  cannot produce.
- three warnings: `strict_roles is off`, `pg_cron is not installed`,
  and `retention has never run`. These are configuration, not defects.
- section 9 to confirm a `pgoutput` slot can be created, because step
  3 enabled logical replication.

Record the result in the table in `docs/managed_providers.md`, with the
engine version. A verification is specific to a major version, so
Aurora PostgreSQL 16 passing says nothing about 14.

## 7. Tear everything down

Do this even if the verification failed. Order matters: the instance
goes before the cluster, and the cluster before the groups it
references.

```bash
aws rds delete-db-instance --db-instance-identifier ${CL}-1 \
  --skip-final-snapshot
aws rds wait db-instance-deleted --db-instance-identifier ${CL}-1

aws rds delete-db-cluster --db-cluster-identifier $CL \
  --skip-final-snapshot
aws rds wait db-cluster-deleted --db-cluster-identifier $CL

aws rds delete-db-subnet-group --db-subnet-group-name ${CL}-subnets
aws rds delete-db-cluster-parameter-group \
  --db-cluster-parameter-group-name ${CL}-params
aws ec2 delete-security-group --group-id $SG
```

Confirm nothing is left, and that the confirmation returns empty
rather than an error you skimmed past:

```bash
aws rds describe-db-clusters \
  --query "DBClusters[?starts_with(DBClusterIdentifier,'volvra')].DBClusterIdentifier" \
  --output text
```

Deleting a cluster does not delete its manual snapshots, so check
those too if any run created one:

```bash
aws rds describe-db-cluster-snapshots --snapshot-type manual \
  --query "DBClusterSnapshots[?starts_with(DBClusterIdentifier,'volvra')].DBClusterSnapshotIdentifier" \
  --output text
```

# Creating the cluster in the console

The order matters in one place: create the parameter group **before**
the database. Choosing it during creation is what avoids a reboot
later, because `rds.logical_replication` is static.

## C1. Create the cluster parameter group first

1. RDS, then **Parameter groups**, then **Create parameter group**.
2. Type must be **DB cluster parameter group**, not the plain DB
    parameter group. The setting pgVolvra's durable tier needs does not
    exist on the instance-level group.
3. Family: `aurora-postgresql` with the major version you intend to
    create, for example `aurora-postgresql16`.
4. Name it `volvra-probe-params` and create it.
5. Open it, **Edit**, search for `rds.logical_replication`, set the
    value to `1`, and save.

## C2. Create the database

1. RDS, then **Databases**, then **Create database**.
2. Choose **Standard create**. Easy create hides public access and the
    parameter group, which are the two settings this exercise needs.
3. Engine type: **Aurora (PostgreSQL Compatible)**. Pick the engine
    version whose major version matches the parameter group family.
4. Templates: **Dev/Test**. Production defaults to a multi-instance
    cluster, which costs more and proves nothing extra here.
5. Cluster identifier: `volvra-probe`. Set the master username and
    password, and keep them: the password cannot contain `/`, `"`,
    `@`, or a space.
6. Instance configuration: **Serverless v2**, minimum capacity
    `0.5` ACU, maximum `2`.
7. Availability: do **not** create an Aurora replica. One writer is
    all this needs.
8. Connectivity: do not connect to an EC2 resource. Leave the default
    VPC selected, set **Public access** to **Yes**, and create a new
    security group named `volvra-probe-sg`. The console adds an
    inbound rule for the address you are connecting from.
9. Open **Additional configuration** and set three things there:
    the **initial database name** to `volvra_probe`, which saves a
    `CREATE DATABASE` later; the **DB cluster parameter group** to
    `volvra-probe-params` from step C1; and **deletion protection**
    off, or the cluster cannot be deleted without another edit.
10. Turn off Enhanced monitoring and Performance Insights. Neither is
    needed, and both cost money.
11. Create the database and wait. This takes around ten minutes.

## C3. Connect

1. RDS, then **Databases**, then the `volvra-probe` cluster.
2. On **Connectivity & security**, copy the **Writer** endpoint. Do
    not use the reader endpoint: it cannot create objects or
    replication slots.
3. Connect, substituting the endpoint and master username:

    ```bash
    export PGHOST=volvra-probe.cluster-xxxx.eu-west-1.rds.amazonaws.com
    export MASTER=volvra_master
    printf 'Master password: '; stty -echo; read -r PGPASSWORD; stty echo; echo
    export PGPASSWORD

    psql "postgres://${MASTER}@${PGHOST}:5432/volvra_probe?sslmode=require" \
      -c "SELECT version()" \
      -c "SELECT current_user, rolsuper FROM pg_roles WHERE rolname = current_user"
    ```

`rolsuper` must be `f`. Then continue at section 5 below, which grants
`rds_replication` and runs the verification.

If the connection hangs rather than failing, it is the network, not
the password: a wrong password is refused immediately. Check that
public access is Yes on the instance, and that the security group has
an inbound rule on 5432 for your current address. A changed address is
the most common cause.

## C4. Delete everything afterwards

1. RDS, then **Databases**, select the cluster, **Actions**, then
    **Delete**. Deleting the cluster deletes its instance.
2. Decline the final snapshot, and confirm. A retained snapshot keeps
    costing money after the cluster is gone.
3. RDS, then **Parameter groups**, and delete `volvra-probe-params`.
4. EC2, then **Security groups**, and delete `volvra-probe-sg`. This
    only succeeds once the cluster is fully deleted.
5. Confirm nothing is left under RDS, Databases, and under RDS,
    Snapshots.
