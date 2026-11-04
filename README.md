# evilflowers-postgresql

PostgreSQL image for the EvilFlowers platform, and reusable for any project that needs it: upstream PostgreSQL with **pgvector**, **ParadeDB pg_search** (BM25) and a curated set of open-source operational extensions, so hybrid dense + lexical search runs inside one database. Multi-arch (amd64 + arm64), signed, rebuilt weekly. It runs under Docker Compose today and under CloudNativePG on Kubernetes later.

```
ghcr.io/evilflowerscatalog/evilflowers-postgresql:18          # stable (default)
ghcr.io/evilflowerscatalog/evilflowers-postgresql:17          # maintenance, for deployments not yet migrated
ghcr.io/evilflowerscatalog/evilflowers-postgresql:19-preview  # preview, never production
```

Deploy the immutable `<minor>-<stamp>` tags listed on each GitHub release, for example `18.6-202611031200`.

## What's inside

| | |
|---|---|
| Base | official [`postgres:<minor>-trixie`](https://hub.docker.com/_/postgres) (Debian 13, PGDG packages), pinned by digest |
| Vector search | **pgvector 0.8.7**, built from source with portable CPU flags |
| Full-text search | **ParadeDB pg_search 0.26.4** (BM25 `bm25` index), from the upstream release package; AGPL-3.0, shipped unmodified. Not in 19-preview yet |
| Preloaded | `pg_stat_statements`, `auto_explain`, `pg_cron`, `pgaudit` (inactive by default), `pg_search` |
| Also installed | `pg_partman`, `pg_repack`, `hypopg`, all contrib modules (`pg_trgm`, `unaccent`, `btree_gin`, ...), pgBackRest |
| Config | tuned `postgresql.conf` and `/etc/postgresql/conf.d/` for host overrides |

Details and reasoning: [docs/tuning.md](docs/tuning.md).

## Quick start

```shell
docker run -d --name pg --shm-size=512m \
  -e POSTGRES_PASSWORD=secret \
  -e POSTGRES_INITDB_ARGS="--locale-provider=builtin --builtin-locale=C.UTF-8" \
  -v pgdata:/var/lib/postgresql \
  -p 127.0.0.1:5432:5432 \
  ghcr.io/evilflowerscatalog/evilflowers-postgresql:18

psql postgresql://postgres:secret@localhost/postgres -c 'CREATE EXTENSION pg_search CASCADE'   # also creates vector
```

The image keeps the official image's environment variables (`POSTGRES_PASSWORD`, `POSTGRES_USER`, `POSTGRES_DB`, `POSTGRES_INITDB_ARGS`, ...) and `/docker-entrypoint-initdb.d`.

> PostgreSQL 18 images mount the volume at **`/var/lib/postgresql`** (data in `18/docker/`), not `/var/lib/postgresql/data`.

Override settings by mounting files into `/etc/postgresql/conf.d/`:

```yaml
volumes:
  - ./my-host.conf:/etc/postgresql/conf.d/50-host.conf:ro
```

## Repository layout

```
Dockerfile                 multi-stage: pgvector build, runtime with PGDG extensions + pg_search
versions.json              build matrix: majors, base images (tag@digest), pgvector, pg_search, extensions
conf/                      image postgresql.conf + per-major drop-ins
initdb/                    first-init hook (pg_stat_statements in template1, pg_cron)
tests/                     smoke test run in CI on every arch
compose/production/        production service definition + example host tuning profile
compose/local/             local development
k8s/cnpg/                  CloudNativePG Cluster + ImageCatalog (+ CI test cluster)
scripts/                   CI helpers (manifest publishing, release notes)
docs/                      release cycle, tuning, upgrade runbook, backups, Kubernetes
```

## Development

Requires Docker with buildx, plus jq and shellcheck.

```shell
make test               # build the default major for your arch, then run tests/smoke.sh
make test MAJOR=17
make lint scan
docker compose -f compose/local/compose.yml up --build
```

## CI/CD

GitHub Actions ([`.github/workflows/build.yml`](.github/workflows/build.yml)):

- Every major × {amd64 on `ubuntu-24.04`, arm64 on `ubuntu-24.04-arm`} builds natively, with no QEMU.
- Each build is smoke-tested and Trivy-scanned (fails on fixable CRITICAL; reviewed, expiring exceptions live in `.trivyignore.yaml`) **before** anything is pushed.
- On `main`, the weekly schedule and manual dispatch: push by digest, build a multi-arch manifest, attach SBOM + provenance, sign with cosign (keyless) and create a GitHub release.
- [`k8s-compat.yml`](.github/workflows/k8s-compat.yml) runs the image under CloudNativePG on kind.
- [Renovate](renovate.json) opens PRs for PostgreSQL minors, base digests, pgvector, pg_search and CI tooling.

Release policy, tags and how changes reach deployments: [docs/release-cycle.md](docs/release-cycle.md).

## Operations

- [Upgrade a deployment from postgres:17](docs/upgrade-17-to-18.md)
- [Tuning](docs/tuning.md)
- [Backups](docs/backups.md)
- [Kubernetes / CloudNativePG](docs/kubernetes.md)

Verify an image:

```shell
cosign verify ghcr.io/evilflowerscatalog/evilflowers-postgresql:18 \
  --certificate-identity-regexp '^https://github.com/EvilFlowersCatalog/evilflowers-postgresql/' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com
```
