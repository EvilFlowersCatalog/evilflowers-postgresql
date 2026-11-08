# Backups

Use two layers. They protect against different failures.

| Layer | Tool | Protects against | Restore granularity |
|---|---|---|---|
| Logical | `pg_dump -Fd` per database, from a scheduled job | dropped tables, bad migrations, moving data between majors | one database or one table |
| Physical + WAL | **pgBackRest** (in the image) to MinIO, or barman-cloud under CNPG | disk loss, corruption, "restore to 14:32 yesterday" | whole cluster, point in time |

Keep at least one copy off the database host, for example on NFS or remote object storage. An object store running on the same machine does not count as off-host.

## pgBackRest to MinIO (compose)

1. Create a bucket and an access key in MinIO, for example `pgbackrest`.
2. Mount a configuration file into the container at `/etc/pgbackrest/pgbackrest.conf`:

   ```ini
   [global]
   repo1-type=s3
   repo1-s3-endpoint=minio.internal
   repo1-s3-uri-style=path
   repo1-s3-verify-tls=n            ; only for MinIO on a private network without TLS
   repo1-storage-port=9000
   repo1-s3-bucket=pgbackrest
   repo1-s3-region=us-east-1
   repo1-path=/main
   repo1-retention-full=4
   repo1-cipher-type=aes-256-cbc
   compress-type=zst
   process-max=2
   start-fast=y

   [main]
   pg1-path=/var/lib/postgresql/18/docker
   ```

   The image ships the Debian CA bundle, so a MinIO endpoint whose certificate chains to a public CA works with `repo1-s3-verify-tls=y` (the default). For a private CA, mount its PEM file and set `repo1-storage-ca-file=/path/to/ca.crt`.

   Pass `PGBACKREST_REPO1_S3_KEY`, `PGBACKREST_REPO1_S3_KEY_SECRET` and `PGBACKREST_REPO1_CIPHER_PASS` as environment variables. Do not write them into the file.

3. Turn on WAL archiving in your host profile (`50-host.conf`), then restart the server:

   ```ini
   archive_mode = on
   archive_command = 'pgbackrest --stanza=main archive-push %p'
   ```

4. Initialise and take the first backup:

   ```shell
   docker compose exec -u postgres db pgbackrest --stanza=main stanza-create
   docker compose exec -u postgres db pgbackrest --stanza=main check
   docker compose exec -u postgres db pgbackrest --stanza=main --type=full backup
   ```

5. Schedule it with a systemd timer on the host: a full backup weekly and a differential daily.

**Test restores.** A backup you have never restored is a hope, not a backup. Once a month, restore into a scratch container and run a smoke query.

## Kubernetes

CloudNativePG handles backups through the Barman Cloud plugin, which uses the same MinIO bucket layout. See [kubernetes.md](kubernetes.md#backups).
