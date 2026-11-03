# syntax=docker/dockerfile:1
#
# EvilFlowers PostgreSQL image.
#
# Built on the official Docker "postgres" image (Debian trixie + PGDG packages),
# so the docker-entrypoint / POSTGRES_* environment contract is unchanged and the
# image also runs under CloudNativePG (set postgresUID/postgresGID to 999).
#
# BASE_IMAGE and PGVECTOR_VERSION come from versions.json via CI (see Makefile).

ARG BASE_IMAGE=postgres:18.6-trixie

# ---------------------------------------------------------------------------
# pgvector, built from a pinned upstream tag.
# PGDG ships only the newest pgvector, so building from source keeps the version
# reproducible and lets us bump it independently of the apt repository.
# ---------------------------------------------------------------------------
FROM ${BASE_IMAGE} AS pgvector

ARG PGVECTOR_VERSION=0.8.7

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# hadolint ignore=DL3008
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      build-essential ca-certificates curl "postgresql-server-dev-${PG_MAJOR}" \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /src
RUN curl -fsSL "https://github.com/pgvector/pgvector/archive/refs/tags/v${PGVECTOR_VERSION}.tar.gz" \
      | tar -xz --strip-components=1

# OPTFLAGS="" disables pgvector's default -march=native: CI runners have a
# different CPU than the servers, so native code could SIGILL in production.
# with_llvm=no skips JIT bitcode (needs clang; we run with jit = off anyway).
# PG_CONFIG is explicit: libpq-dev ships /usr/bin/pg_config of the newest PGDG
# major, which would build 17/19 images against the wrong server headers.
RUN pgconfig="/usr/lib/postgresql/${PG_MAJOR}/bin/pg_config" \
 && make -j"$(nproc)" PG_CONFIG="$pgconfig" OPTFLAGS="" with_llvm=no \
 && make install PG_CONFIG="$pgconfig" OPTFLAGS="" with_llvm=no DESTDIR=/out \
 && test -f "/out/usr/lib/postgresql/${PG_MAJOR}/lib/vector.so"

# ---------------------------------------------------------------------------
# Runtime image
# ---------------------------------------------------------------------------
FROM ${BASE_IMAGE}

ARG BASE_IMAGE
ARG PGVECTOR_VERSION=0.8.7
ARG EXTENSIONS="cron repack hypopg pgaudit partman"
ARG VERSION=dev
ARG REVISION=unknown
ARG CREATED=unknown

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# Extensions from the PostgreSQL apt repository (apt.postgresql.org), plus
# pgBackRest for physical backups to S3 (MinIO) when running under compose.
# PGDG keeps only the current package versions, so they are not pinned. CI
# records what was installed in /usr/share/evilflowers/manifest.txt.
# hadolint ignore=DL3008
RUN apt-get update \
 && pkgs=(pgbackrest) \
 && for ext in ${EXTENSIONS}; do pkgs+=("postgresql-${PG_MAJOR}-${ext}"); done \
 && apt-get install -y --no-install-recommends "${pkgs[@]}" \
 && rm -rf /var/lib/apt/lists/* \
 && mkdir -p /usr/share/evilflowers \
 && { echo "postgresql $(postgres --version | awk '{print $3}')"; \
      echo "pgvector ${PGVECTOR_VERSION}"; \
      dpkg-query -W -f='${Package} ${Version}\n' "${pkgs[@]}"; } \
      > /usr/share/evilflowers/manifest.txt

COPY --from=pgvector /out/usr/ /usr/

# Configuration: a full postgresql.conf with conservative defaults, a
# version-specific drop-in, and /etc/postgresql/conf.d for host overrides
# (mounted by compose). Files in conf.d load in alphabetical order.
COPY conf/postgresql.conf /etc/postgresql/postgresql.conf
COPY conf/version/ /tmp/conf-version/
RUN mkdir -p /etc/postgresql/conf.d \
 && if [[ -f "/tmp/conf-version/${PG_MAJOR}.conf" ]]; then \
      cp "/tmp/conf-version/${PG_MAJOR}.conf" /etc/postgresql/conf.d/00-version.conf; \
    fi \
 && rm -rf /tmp/conf-version \
 && chown -R postgres:postgres /etc/postgresql

COPY initdb/ /docker-entrypoint-initdb.d/

LABEL org.opencontainers.image.title="evilflowers-postgresql" \
      org.opencontainers.image.description="PostgreSQL ${PG_MAJOR} with pgvector ${PGVECTOR_VERSION} and operational extensions for EvilFlowers" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.revision="${REVISION}" \
      org.opencontainers.image.created="${CREATED}" \
      org.opencontainers.image.licenses="PostgreSQL" \
      org.opencontainers.image.base.name="${BASE_IMAGE}" \
      io.github.evilflowerscatalog.pgvector.version="${PGVECTOR_VERSION}"

# Probe over TCP. During first-time init the entrypoint's temporary server
# listens only on the Unix socket, so the container reports healthy only once
# initialisation has finished.
HEALTHCHECK --interval=10s --timeout=5s --start-period=60s --retries=5 \
  CMD pg_isready -h 127.0.0.1 -p 5432 -q || exit 1

STOPSIGNAL SIGINT
CMD ["postgres", "-c", "config_file=/etc/postgresql/postgresql.conf"]
