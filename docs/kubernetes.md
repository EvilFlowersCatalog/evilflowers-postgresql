# Running on Kubernetes

Target: [CloudNativePG](https://cloudnative-pg.io) (Apache-2.0, a CNCF project). It is the most widely used open-source PostgreSQL operator. It handles replicas, automated failover, rolling minor upgrades, backups to S3/MinIO with point-in-time recovery, and declarative roles and databases. It runs on any conformant distribution, including k3s, so it can sit next to an existing compose stack while the migration happens.

## Why this image works under CNPG

CNPG injects its own instance manager as PID 1 and ignores the image's entrypoint, `CMD` and baked `postgresql.conf`. All it needs is the PostgreSQL binaries on `PATH`, which the official Debian image provides. Two things differ from CNPG's own images:

- **UID/GID 999** instead of 26, so set `postgresUID: 999` and `postgresGID: 999`. `k8s/cnpg/cluster.yaml` does this.
- **Configuration** lives in `spec.postgresql.parameters`. CNPG adds `pg_stat_statements`, `auto_explain` and `pgaudit` to `shared_preload_libraries` itself when their parameters are present. List only `pg_cron` explicitly.

`.github/workflows/k8s-compat.yml` checks this every week on kind. It deploys a 1-instance cluster with the default major and checks `vector`, `pg_search` and `pg_cron`.

## Replicas and pg_search

Community ParadeDB `pg_search` does not support physical replication. When a standby replays the WAL of a `bm25` index, its startup process stops with:

```
FATAL: replicas are not supported on community and require paradedb enterprise,
       which guarantees physical replication safety on standbys.
CONTEXT: WAL redo at … for pg_search/INIT_INDEX
```

The standby keeps restarting and never streams again. Under CNPG this means:

- A database with `bm25` indexes runs on **one instance**, which is what `k8s/cnpg/cluster.yaml` sets. There is no streaming replica and no automated failover; recovery comes from backups (Barman Cloud plugin, point-in-time recovery).
- More instances work only while no database has a `bm25` index. Creating the first one takes every standby down.
- For replicas with BM25, a pg_search edition that supports physical replication is needed (ParadeDB Enterprise), or the BM25 tables move to a separate single-instance cluster.

This was observed with pg_search 0.26.4 under CNPG 1.30 in CI. The compose deployment has no standbys and is not affected.

## Install

```shell
kubectl apply --server-side -f \
  https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/release-1.30/releases/cnpg-1.30.1.yaml
kubectl apply -f k8s/cnpg/image-catalog.yaml
kubectl apply -f k8s/cnpg/cluster.yaml
kubectl cnpg status evilflowers-db        # kubectl plugin: https://cloudnative-pg.io/docs/current/kubectl-plugin
```

On single-node clusters such as k3s, the `local-path` storage class works if it points at a fast data disk. Otherwise use a dedicated `StorageClass`. Keep WAL on its own volume (`walStorage`), as the example does.

## Upgrades under CNPG

- **Minor release or rebuild:** change the image for the major in `ImageCatalog` to the new immutable tag. `k8s/cnpg/cluster.yaml` runs one instance ([above](#replicas-and-pg_search)), so CNPG restarts the primary in place, and the database is down while PostgreSQL restarts. With replicas, CNPG would restart them first, then switch over, and downtime would be only a few seconds.
- **Major release:** CNPG (1.26+) supports declarative in-place major upgrades with `pg_upgrade`. Point `imageCatalogRef.major` at the new major. `pg_upgrade` needs matching locale and checksum settings, which is why this repository standardises on builtin `C.UTF-8` with checksums on. Rehearse on a clone first, for example with a cluster bootstrapped through `bootstrap.recovery` from the latest backup.

## Backups

Use the Barman Cloud plugin (`plugin-barman-cloud`) with an `ObjectStore` that points at MinIO, plus a `ScheduledBackup`. Since CNPG 1.26 the plugin runs as a sidecar, so the PostgreSQL image does not need `barman-cloud` installed. See the CNPG documentation, "Backup" and "Barman Cloud plugin".

## Moving a compose deployment to CNPG

Use a logical import. It moves only the databases you choose, and lets CNPG own the new cluster's layout:

```yaml
bootstrap:
  initdb:
    import:
      type: monolith               # several databases + roles in one go
      databases: [app1, app2]
      roles: ["*"]
      source:
        externalCluster: compose-db
externalClusters:
  - name: compose-db
    connectionParameters:
      host: db.example.internal    # must be reachable from the pod network
      user: postgres
      dbname: postgres
    password:
      name: compose-db-superuser
      key: password
```

Stop writers during the import, as in the 17→18 runbook. Then switch the applications' `DATABASE_URL` to the `evilflowers-db-rw` service, or put pgcat or PgBouncer in front through CNPG's `Pooler` resource.

## Alternative: extension image volumes

CNPG 1.27+ can mount extensions from separate OCI images (`spec.postgresql.extensions`, which needs Kubernetes ImageVolume support). That would allow a minimal CNPG base plus a pgvector image. This repository bakes the extensions in instead, so the same image runs under compose and under Kubernetes. Revisit the choice once no deployment uses compose any more.
