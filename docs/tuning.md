# Tuning

Configuration comes in three layers. Later layers win:

1. `conf/postgresql.conf` is baked into the image. It holds conservative defaults that are safe on a 2 GB container, plus `shared_preload_libraries` and logging.
2. `conf/version/<major>.conf` is baked in as `conf.d/00-version.conf` and holds settings that exist only in some majors, such as `io_method` in 18+.
3. The host profile is mounted into `/etc/postgresql/conf.d/`, for example `compose/production/50-host.conf`.

Check what is active and where it came from:

```sql
SELECT name, setting, unit, sourcefile, sourceline FROM pg_settings WHERE source NOT IN ('default', 'override') ORDER BY name;
```

Under CloudNativePG, layers 1–3 are replaced by `spec.postgresql.parameters`; see [kubernetes.md](kubernetes.md).

## Sizing a host profile

Start from the memory **budget** you give PostgreSQL (the container `mem_limit`), not from host RAM. The example profile assumes a shared host with 8 vCPU and 32 GiB, where PostgreSQL gets a 10 GiB budget.

| Setting | Rule of thumb | example (8 vCPU, 10 GiB budget) |
|---|---|---|
| `shared_buffers` | 25–40 % of budget | 4 GB |
| `effective_cache_size` | shared_buffers + OS page cache realistically available | 12 GB |
| `work_mem` | (budget − shared_buffers) / (active connections × 2–3); raise per role for reports | 16 MB |
| `maintenance_work_mem` | 5–10 % of budget, at most 2 GB globally | 1 GB |
| `autovacuum_work_mem` | maintenance_work_mem / autovacuum_max_workers | 256 MB |
| `max_parallel_workers` | vCPUs − 2 | 6 |
| `max_parallel_maintenance_workers` | vCPUs / 2 | 4 |
| `io_workers` (18) / `io_min_workers` (19+) | 3 by default; raise if `pg_aios` shows a backlog. 19 removed `io_workers`: the pool scales between `io_min_workers` and `io_max_workers`, and a leftover `io_workers` line stops the server from starting | 3 |
| `max_wal_size` | enough for one `checkpoint_timeout` of peak WAL; check `log_checkpoints` for "requested" checkpoints | 4 GB |
| `max_connections` | sum of pooler server pools + direct clients + 20 % | 200 |

`random_page_cost = 1.1` and `effective_io_concurrency = 200` assume SSD or NVMe-backed storage. If your storage turns out to sit on spinning disks, set `random_page_cost = 2` and measure.

PostgreSQL 18 adds asynchronous I/O. Keep `io_method = worker`. `io_uring` is faster, but Docker's default seccomp profile and most Kubernetes runtimes block it.

## Container / host settings that matter

- **`shm_size`.** Parallel query and parallel index builds (including pgvector HNSW) use dynamic shared memory in `/dev/shm`. Docker's default of 64 MB causes `could not resize shared memory segment`. The compose files set 1 GB.
- **`stop_grace_period`.** Docker sends SIGKILL after 10 s by default. A large shutdown checkpoint takes longer, and the next start then runs crash recovery. Compose sets 2 minutes.
- **`mem_limit` and OOM.** This matters most on hosts without swap. The cgroup limit keeps PostgreSQL inside its budget, and `oom_score_adj: -500` makes the kernel prefer other victims over the postmaster.
- **Huge pages (optional).** `huge_pages = try` uses them if the host provides them. For 4 GB shared_buffers, set `vm.nr_hugepages = 2200` (2 MiB pages) in `/etc/sysctl.d/`. With shared_buffers this small the gain is modest, so the step is optional.
- **Transparent huge pages.** Set them to `madvise` (Ubuntu's default) and never to `always`, which causes latency spikes.

## Connection pooling

`max_connections = 200` is a ceiling, not a target. Every backend costs memory. Route busy applications through a pooler such as **pgcat** or **PgBouncer** in transaction mode. Small tools with their own small pools can connect directly. Move them behind the pooler too if `pg_stat_activity` regularly exceeds about 100 connections.

Transaction pooling breaks session state: `SET` without `LOCAL`, advisory session locks, `LISTEN` and server-side prepared statements outside pgcat's support. Django is fine with `CONN_MAX_AGE = 0` or with pgcat's prepared-statement support.

## pgvector

- Build HNSW indexes with a session-level memory boost. Indexes that do not fit in `maintenance_work_mem` build much slower:

  ```sql
  SET maintenance_work_mem = '4GB';           -- within the container budget
  SET max_parallel_maintenance_workers = 4;
  CREATE INDEX CONCURRENTLY ON chunks USING hnsw (embedding vector_cosine_ops) WITH (m = 16, ef_construction = 64);
  ```

- Query-time recall/speed trade-off: `SET hnsw.ef_search = 100;` (default 40).
- Filtered searches: turn on iterative scans (pgvector 0.8+) so a `WHERE` filter does not starve the result. Use `SET hnsw.iterative_scan = relaxed_order;`.
- Storage: `halfvec` halves the size of the index and table for float embeddings with negligible recall loss. Index `binary_quantize(embedding)::bit(n)` and re-rank for very large collections.
- After a pgvector upgrade, run `ALTER EXTENSION vector UPDATE;` in each database that uses it.

## pg_search (BM25)

[ParadeDB `pg_search`](https://github.com/paradedb/paradedb) adds a `bm25` index type: real BM25 ranking with corpus-wide IDF, which `ts_rank` lacks. It is preloaded, and each database enables it with `CREATE EXTENSION pg_search;`. It requires `vector`; add `CASCADE` if `vector` is not created yet.

```sql
CREATE INDEX chunks_bm25_idx ON chunks USING bm25 (id, text);

SELECT id, pdb.score(id) AS score
FROM chunks WHERE text ||| 'hľadaný výraz'
ORDER BY score DESC LIMIT 20;
```

- One table can have only one `bm25` index, so list every searchable column in it. Since 0.26 the `key_field` option is deprecated and ignored.
- Hybrid search: fuse the BM25 branch with a pgvector `ORDER BY embedding <=> $1` branch by reciprocal rank fusion, `sum(1.0 / (60 + rank))`, in one query. `tests/smoke.sql` has a working example.
- Tokenizers and stemmers are chosen per column in the index definition. Check the ParadeDB documentation for the languages your data needs before building large indexes, because changing the tokenizer means rebuilding the index.
- After a pg_search upgrade, run `ALTER EXTENSION pg_search UPDATE;` in each database that uses it, and `REINDEX` when the release notes ask for it.
- No physical standbys: community pg_search stops a replica as soon as it replays a `bm25` index's WAL ("replicas are not supported on community"). Under CloudNativePG, run such a database on one instance ([kubernetes.md](kubernetes.md#replicas-and-pg_search)).
- Not packaged for every major: a major marked `"pg_search": false` in `versions.json` is built without it (19 is like this until ParadeDB publishes PostgreSQL 19 packages).

## Observability

- **`pg_stat_statements`** is preloaded and created in every new database through `template1`. Start with:

  ```sql
  SELECT calls, round(total_exec_time) AS ms, round(mean_exec_time, 1) AS mean_ms, query
  FROM pg_stat_statements ORDER BY total_exec_time DESC LIMIT 20;
  ```

- **Logs:** statements over 1 s, plans of statements over 5 s (`auto_explain`), lock waits, temp files over 64 MB and autovacuum runs over 10 s go to stderr. [pgBadger](https://github.com/darold/pgbadger) can turn `docker logs` output into a report.
- **Metrics:** `prometheuscommunity/postgres-exporter`. Add `--collector.stat_statements` and `--collector.long_running_transactions`.
- **Monitoring settings:** these feed latency data to the exporter and to the logs. All of them need a restart or apply only at session start, so they are image config, not `ALTER SYSTEM`:

  | Setting | Value | Where | What it feeds |
  |---|---|---|---|
  | `track_io_timing` | `on` | all majors | `pg_stat_io`, `pg_stat_database.blk_*_time`, `pg_stat_statements.shared_blk_*_time` |
  | `track_wal_io_timing` | `on` | all majors | WAL write and fsync time. Since 18 it is in `pg_stat_io` (`object = 'wal'`) |
  | `track_activity_query_size` | `4096` | all majors | longer `pg_stat_activity.query` text; ORM queries get cut at the 1 kB default. Restart only |
  | `log_connections` | `setup_durations` | 18+ (`00-version.conf`) | one log line per connection with the total setup, fork and auth time: client-visible connection latency, readable in Loki, without the receipt and auth lines of `on` |
  | `track_cost_delay_timing` | `on` | 18+ (`00-version.conf`) | time vacuum spends in cost-based sleep, in `pg_stat_progress_vacuum` |
  | `pg_stat_statements.track_planning` | `off` | all majors | `*_plan_time` columns. Off because the documentation warns of noticeable overhead; enable it in a host profile if plan time matters |

  17 rejects the list syntax of `log_connections` and has no `track_cost_delay_timing`, so those two live in the version drop-in and 17 keeps `log_connections = off`. Under CloudNativePG they are set in `spec.postgresql.parameters` in `k8s/cnpg/cluster.yaml`.

- **Index advice:** test candidate indexes without building them, using `hypopg`:

  ```sql
  SELECT * FROM hypopg_create_index('CREATE INDEX ON entries (created_at)');
  EXPLAIN SELECT ...;
  ```

- **Bloat:** `pg_repack` rebuilds bloated tables and indexes online, unlike `VACUUM FULL`, which takes an exclusive lock.

## Bundled extensions

| Extension | Source | Preloaded | Purpose |
|---|---|---|---|
| `vector` | pgvector, built from source | no | embeddings, HNSW/IVFFlat, halfvec/sparsevec/bit |
| `pg_search` | ParadeDB release `.deb` (AGPL-3.0) | yes | BM25 full-text search index (`bm25`), lexical half of hybrid search |
| `pg_stat_statements` | contrib | yes | query statistics |
| `auto_explain` | contrib | yes | logs slow plans |
| `pg_cron` | PGDG | yes | in-database job scheduler (`cron.schedule_in_database`) |
| `pgaudit` | PGDG | yes (inactive) | audit logging, when compliance needs it |
| `pg_partman` | PGDG | no | time/serial partition management, for logs and events |
| `pg_repack` | PGDG | no | online table and index rebuilds |
| `hypopg` | PGDG | no | hypothetical indexes |
| `age` | PGDG (Apache-2.0) | no (per database: `session_preload_libraries`, see README) | Apache AGE property graph and Cypher queries. Not in 19-preview (`"age": false`) |
| `pg_trgm`, `unaccent`, `btree_gin`, `fuzzystrmatch`, ... | contrib | no | fuzzy search and accent-insensitive Slovak search |

Also installed: **pgBackRest**, for physical backups and point-in-time recovery to MinIO/S3 under compose (see [backups.md](backups.md)).

Not included on purpose:

- **PostGIS:** large, and nothing in EvilFlowers uses geodata. Add `postgis-3` to `extensions` in `versions.json` if that changes.
- **pgvectorscale:** not packaged by PGDG.
- **VectorChord:** licensed under AGPL/ELv2, and pgvector covers the expected scale. `pg_search` is the one AGPL component and is shipped unmodified because nothing permissive offers BM25 inside PostgreSQL. Using it from an application does not put the application under the AGPL; modifying `pg_search` itself would.
