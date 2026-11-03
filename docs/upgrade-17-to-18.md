# Upgrading a Docker Compose deployment from `postgres:17` to this image (PostgreSQL 18)

> **Changing the image tag is not enough.** The PostgreSQL 18 Docker image keeps
> its data in `/var/lib/postgresql/18/docker` and declares the volume at
> `/var/lib/postgresql`. A typical `postgres:17` service mounts its volume at
> `/var/lib/postgresql/data`. If you only swap the tag, 18 either initialises a
> new empty cluster or refuses to start. In both cases the data has to be migrated.

The commands below assume a compose service `db` running `postgres:17` with a volume `postgresql_data`, and `.env` variables `POSTGRES_USER` / `POSTGRES_PASSWORD`. Replace `DATABASES` with your own list. Remember that compose prefixes volume names with the project name (`<project>_postgresql_data`).

## Choose a method

| | Dump and restore (recommended) | `pg_upgrade --link` |
|---|---|---|
| Downtime | proportional to data size (minutes for a few GB) | about a minute, whatever the size |
| Data checksums | **on** (the 18 default) | must match 17, so **off** unless you run `pg_checksums --enable` on 17 first (offline, rewrites every file) |
| Collation | can move to builtin `C.UTF-8` (see below) | must stay the same as the old cluster (usually `en_US.utf8`, glibc) |
| Bloat | rebuilt from scratch, indexes compact | carried over |
| Risk | low; the old volume is untouched | the old cluster cannot be started once the new one has run |

Measure before you decide:

```sql
SELECT datname, pg_size_pretty(pg_database_size(datname)) FROM pg_database ORDER BY pg_database_size(datname) DESC;
```

Dump and restore suits most deployments. Consider `pg_upgrade` only if the total is well above about 100 GB or the downtime budget is very tight.

### Collation change: read before migrating

The official image initialises clusters with glibc `en_US.utf8`. The recommended new default is the builtin `C.UTF-8` provider. It does not depend on glibc, so rebuilding on a newer Debian can never silently corrupt text indexes. The trade-off is that `ORDER BY` on text becomes code-point order, which is not linguistic order.

- Where users see sorted text (titles, names), sort with an ICU collation, for example `ORDER BY title COLLATE "sk-x-icu"` or `"en-x-icu"`, or declare the column with that collation.
- To keep today's behaviour exactly, restore into databases created with `LOCALE_PROVIDER libc LOCALE 'en_US.utf8'`. They still need `REINDEX` after future glibc major updates.

## Procedure (dump and restore)

Rehearse it first on a copy, for example by restoring a recent backup into a scratch container.

```shell
DATABASES="app1 app2"        # every database you want to keep
```

### 1. Inventory (no downtime)

```shell
docker compose exec db psql -U postgres -c '\l+'
docker compose exec db psql -U postgres -c '\du'
docker compose exec db psql -U postgres -c '\drds'          # per-database/role settings
for db in $DATABASES; do
  docker compose exec db psql -U postgres -d "$db" -Atc "SELECT '$db', extname, extversion FROM pg_extension"
done
```

Every extension in use must exist in the new image. `plpgsql`, contrib, `vector`, `pg_cron`, `pg_repack`, `hypopg`, `pgaudit` and `pg_partman` are included. Also check that each application supports PostgreSQL 18.

### 2. Start the new server next to the old one (no downtime)

GHCR creates packages as **private** on the first push. Either make `evilflowers-postgresql` public in the organisation's package settings, or run `docker login ghcr.io` on the host with a read-only token. Otherwise the pull fails with 401.

Add a temporary service `db18` to your `compose.yml`, copied from the `db` service in `compose/production/compose.yml`. Give it no published port, or a different one. Then:

```shell
mkdir -p postgresql && cp /path/to/this/repo/compose/production/50-host.conf postgresql/   # size it first
docker compose up -d db18
docker compose logs -f db18      # wait for "database system is ready to accept connections"
```

### 3. Stop writers (downtime starts)

Stop every application and pooler that connects to `db`. Then make sure nothing is left:

```shell
docker compose exec db psql -U postgres -c "SELECT datname, usename, application_name FROM pg_stat_activity WHERE backend_type = 'client backend'"
```

### 4. Roles, then each database

Run pg_dump from the **18** container, because a newer pg_dump can read an older server:

```shell
# roles and passwords (SCRAM hashes carry over)
docker compose exec -T db pg_dumpall -U postgres --globals-only \
  | docker compose exec -T db18 psql -U postgres -v ON_ERROR_STOP=0 -d postgres
#   "role postgres already exists" is expected

for db in $DATABASES; do
  owner=$(docker compose exec -T db psql -U postgres -Atc "SELECT pg_get_userbyid(datdba) FROM pg_database WHERE datname='$db'")
  # create with the NEW cluster defaults (builtin C.UTF-8, checksums on)
  docker compose exec -T db18 psql -U postgres -c "CREATE DATABASE \"$db\" OWNER \"$owner\" TEMPLATE template0"
  docker compose exec -T db18 bash -c "
    export PGPASSWORD=\"\$POSTGRES_PASSWORD\"
    pg_dump -h db -U postgres -Fd -j 4 -f /var/lib/postgresql/dump-$db '$db' &&
    pg_restore -U postgres -d '$db' -j 4 --exit-on-error /var/lib/postgresql/dump-$db &&
    rm -rf /var/lib/postgresql/dump-$db"
done
```

Then re-apply any per-database settings found by `\drds`, for example `ALTER DATABASE … SET search_path …`. A restore into an existing database does not carry them over.

### 5. Refresh planner statistics

```shell
docker compose exec db18 vacuumdb -U postgres --all --analyze-in-stages -j 4
```

### 6. Cut over

1. Stop and remove the old service: `docker compose stop db && docker compose rm -f db`. Its volume stays.
2. Replace the `db` service with the new definition (same `postgresql18_data` volume key as `db18`) and remove the temporary `db18` service. Because both use the same volume key, the restored data carries over.
3. Run `docker compose up -d db`, then start the poolers and applications.

   Check that every client still resolves the server's host name. Poolers and apps sometimes use a container name or network alias other than `db`. Add `aliases:` under the service's network if needed.

4. Verify: `SELECT version();`, log in to each application, and check that `pg_stat_statements` and any cron jobs work. Run a known pgvector query.

### 7. Afterwards

- Keep the old 17 volume for at least two weeks, then remove it.
- Point monitoring (for example `postgres_exporter`) at the new server and add `--collector.stat_statements`.

### Rollback

Writes after the cutover would be lost, so decide quickly. To roll back, stop `db`, restore the old service definition (`postgres:17` with `postgresql_data:/var/lib/postgresql/data`) and start it. The old volume was never modified.

## Alternative: `pg_upgrade --link`

If the data is too large for dump and restore, use the open-source [`tianon/postgres-upgrade:17-to-18`](https://github.com/tianon/docker-postgres-upgrade) image. Initialise the new cluster to match the old one (`POSTGRES_INITDB_ARGS="--no-data-checksums --locale=en_US.utf8"`), lay the volumes out as that image's README describes, and run `pg_upgrade --link --check` first. PostgreSQL 18's pg_upgrade keeps planner statistics, so you only need `vacuumdb --analyze-in-stages --missing-stats-only`.
