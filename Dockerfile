# syntax=docker/dockerfile:1
#
# EvilFlowers PostgreSQL image.
#
# Built on the official Docker "postgres" image (Debian trixie + PGDG packages),
# so the docker-entrypoint / POSTGRES_* environment contract is unchanged and the
# image also runs under CloudNativePG (set postgresUID/postgresGID to 999).
#
# BASE_IMAGE, PGVECTOR_VERSION, PG_SEARCH_VERSION and EXTENSIONS come from
# versions.json via CI (see Makefile). An empty PG_SEARCH_VERSION builds the image
# without pg_search; EXTENSIONS already leaves out what a major opts out of.

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
# Slovak and Czech full-text search dictionaries for the ispell template.
# PostgreSQL ships no Slovak or Czech stemmer. The hunspell dictionaries come
# from Debian trixie (hunspell-sk, hunspell-cs: the LibreOffice dictionaries,
# already UTF-8). The packages are only unpacked, not installed, so their
# dictionaries-common dependency stays out of the image. The stop lists are
# vendored in tsearch_data/ (provenance in tsearch_data/README.md).
# Only the files are shipped; the app creates the text search objects.
# ---------------------------------------------------------------------------
FROM ${BASE_IMAGE} AS tsearch

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

WORKDIR /src
COPY tsearch_data/*.stop /src/

# The target path is spelled out rather than taken from pg_config, which may
# belong to a different major (see the pgvector stage).
# hadolint ignore=SC2016
RUN apt-get update \
 && apt-get download hunspell-sk hunspell-cs \
 && rm -rf /var/lib/apt/lists/* \
 && dest="/out/usr/share/postgresql/${PG_MAJOR}/tsearch_data" \
 && mkdir -p "$dest" /out/usr/share/evilflowers \
 && for deb in hunspell-sk_*.deb hunspell-cs_*.deb; do \
      dpkg-deb -x "$deb" pkg \
      && dpkg-deb -W --showformat='${Package} ${Version}\n' "$deb" >> /out/usr/share/evilflowers/manifest-tsearch.txt; \
    done \
 && for dict in sk_SK cs_CZ; do \
      cp -L "pkg/usr/share/hunspell/${dict}.aff" "${dest}/${dict,,}.affix" \
      && cp -L "pkg/usr/share/hunspell/${dict}.dic" "${dest}/${dict,,}.dict"; \
    done \
 && cp slovak.stop czech.stop "$dest/" \
 && chmod 0644 "$dest"/*

# ---------------------------------------------------------------------------
# Runtime image
# ---------------------------------------------------------------------------
FROM ${BASE_IMAGE}

ARG BASE_IMAGE
ARG PGVECTOR_VERSION=0.8.7
ARG PG_SEARCH_VERSION=0.26.4
ARG EXTENSIONS="cron repack hypopg pgaudit partman age"
ARG VERSION=dev
ARG REVISION=unknown
ARG CREATED=unknown

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

COPY --from=tsearch /out/usr/ /usr/

# Extensions from the PostgreSQL apt repository (apt.postgresql.org), plus
# pgBackRest for physical backups to S3 (MinIO) when running under compose,
# and the system CA bundle (ca-certificates) so pgBackRest and libpq can
# verify TLS peers (for a private CA, mount it and set repo1-storage-ca-file).
# PGDG keeps only the current package versions, so they are not pinned. CI
# records what was installed in /usr/share/evilflowers/manifest.txt.
# Apache AGE (postgresql-<major>-age, Apache-2.0) is one of them. It needs no
# shared_preload_libraries entry: a session runs LOAD '$libdir/plugins/age', or
# a database sets session_preload_libraries = '$libdir/plugins/age', so
# databases that do not use it are unaffected. PostgreSQL lets a non-superuser
# LOAD only libraries under $libdir/plugins/, so age.so is symlinked there; the
# extension's own functions keep referring to $libdir/age (same file, loaded
# once). The path is spelled out because pg_config may belong to another major.
# hadolint ignore=DL3008
RUN apt-get update \
 && pkgs=(ca-certificates pgbackrest) \
 && for ext in ${EXTENSIONS}; do pkgs+=("postgresql-${PG_MAJOR}-${ext}"); done \
 && apt-get install -y --no-install-recommends "${pkgs[@]}" \
 && rm -rf /var/lib/apt/lists/* \
 && if [[ " ${EXTENSIONS} " == *" age "* ]]; then \
      mkdir -p "/usr/lib/postgresql/${PG_MAJOR}/lib/plugins" \
      && ln -s ../age.so "/usr/lib/postgresql/${PG_MAJOR}/lib/plugins/age.so" \
      && test -e "/usr/lib/postgresql/${PG_MAJOR}/lib/plugins/age.so"; \
    fi \
 && mkdir -p /usr/share/evilflowers \
 && { echo "postgresql $(postgres --version | awk '{print $3}')"; \
      echo "pgvector ${PGVECTOR_VERSION}"; \
      dpkg-query -W -f='${Package} ${Version}\n' "${pkgs[@]}"; \
      cat /usr/share/evilflowers/manifest-tsearch.txt; } \
      > /usr/share/evilflowers/manifest.txt \
 && rm /usr/share/evilflowers/manifest-tsearch.txt

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

# ParadeDB pg_search (BM25 full-text search), from the signed upstream .deb of a
# pinned release. The package depends only on postgresql-<major> and
# libopenblas0, so it does not replace the pgvector built above (pg_search
# requires the vector extension since 0.25). It must be preloaded, so it is
# appended to shared_preload_libraries here, in the same step that installs it:
# a major without pg_search keeps the plain list and still starts.
# pg_search is AGPL-3.0; it is shipped unmodified, source at
# https://github.com/paradedb/paradedb/tree/v${PG_SEARCH_VERSION}.
# hadolint ignore=DL3008
RUN if [[ -n "${PG_SEARCH_VERSION}" ]]; then \
      deb="postgresql-${PG_MAJOR}-pg-search_${PG_SEARCH_VERSION}-1PARADEDB-trixie_$(dpkg --print-architecture).deb" \
      && apt-get update \
      && apt-get install -y --no-install-recommends curl \
      && curl -fsSL -o "/tmp/${deb}" "https://github.com/paradedb/paradedb/releases/download/v${PG_SEARCH_VERSION}/${deb}" \
      && apt-get install -y --no-install-recommends "/tmp/${deb}" \
      && apt-get purge -y --auto-remove curl \
      && rm -rf /var/lib/apt/lists/* "/tmp/${deb}" \
      && test -f "/usr/lib/postgresql/${PG_MAJOR}/lib/pg_search.so" \
      && sed -i -E "s/^(shared_preload_libraries = '[^']*)'/\1,pg_search'/" /etc/postgresql/postgresql.conf \
      && grep -q "^shared_preload_libraries = '.*,pg_search'" /etc/postgresql/postgresql.conf \
      && dpkg-query -W -f='${Package} ${Version}\n' "postgresql-${PG_MAJOR}-pg-search" >> /usr/share/evilflowers/manifest.txt; \
    fi

COPY initdb/ /docker-entrypoint-initdb.d/

LABEL org.opencontainers.image.title="evilflowers-postgresql" \
      org.opencontainers.image.description="PostgreSQL ${PG_MAJOR} with pgvector ${PGVECTOR_VERSION}, ParadeDB pg_search, Apache AGE, Slovak/Czech full-text dictionaries and operational extensions for EvilFlowers" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.revision="${REVISION}" \
      org.opencontainers.image.created="${CREATED}" \
      org.opencontainers.image.licenses="PostgreSQL AND AGPL-3.0-only AND GPL-2.0-only AND MIT AND Apache-2.0" \
      org.opencontainers.image.base.name="${BASE_IMAGE}" \
      io.github.evilflowerscatalog.pgvector.version="${PGVECTOR_VERSION}" \
      io.github.evilflowerscatalog.pg_search.version="${PG_SEARCH_VERSION}"

# Probe over TCP. During first-time init the entrypoint's temporary server
# listens only on the Unix socket, so the container reports healthy only once
# initialisation has finished.
HEALTHCHECK --interval=10s --timeout=5s --start-period=60s --retries=5 \
  CMD ["sh", "-c", "pg_isready -h 127.0.0.1 -p 5432 -q || exit 1"]

STOPSIGNAL SIGINT
CMD ["postgres", "-c", "config_file=/etc/postgresql/postgresql.conf"]
