#!/usr/bin/env bash
# Smoke-test a built image.
#
#   tests/smoke.sh <image> [expected-pgvector-version] [expected-pg_search-version] [extensions]
#
# Starts the image with an empty volume, waits for it to be healthy, runs
# tests/smoke.sql, checks versions and settings, then restarts the container on
# the same volume to prove an existing data directory starts cleanly.
# An empty pg_search version means the image is built without pg_search: the
# test then also checks that it is absent and not preloaded.
# [extensions] is the EXTENSIONS build argument (PGDG packages, space-separated).
# It decides whether Apache AGE is expected; without it, AGE is expected.
set -Eeuo pipefail

IMAGE="${1:?usage: smoke.sh <image> [pgvector-version] [pg_search-version] [extensions]}"
EXPECTED_PGVECTOR="${2:-}"
EXPECTED_PG_SEARCH="${3:-}"
EXTENSIONS="${4-age}"
HAS_PG_SEARCH=0
[[ -n "$EXPECTED_PG_SEARCH" ]] && HAS_PG_SEARCH=1
HAS_AGE=0
[[ " $EXTENSIONS " == *" age "* ]] && HAS_AGE=1
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAME="pg-smoke-$$"
VOLUME="pg-smoke-$$"

cleanup() {
  local rc=$?
  if [[ $rc -ne 0 ]]; then
    echo "---- container logs ----"
    docker logs "$NAME" 2>&1 | tail -n 100 || true
  fi
  docker rm -f "$NAME" >/dev/null 2>&1 || true
  docker volume rm -f "$VOLUME" >/dev/null 2>&1 || true
  exit "$rc"
}
trap cleanup EXIT

wait_healthy() {
  local status
  for _ in $(seq 1 90); do
    status="$(docker inspect -f '{{.State.Health.Status}}' "$NAME" 2>/dev/null || echo missing)"
    case "$status" in
      healthy) return 0 ;;
      unhealthy|missing) echo "container is $status" >&2; return 1 ;;
    esac
    sleep 2
  done
  echo "timed out waiting for healthy container" >&2
  return 1
}

psql_c() {
  docker exec "$NAME" psql -X -v ON_ERROR_STOP=1 -U postgres -d postgres -Atc "$1"
}

echo "==> starting $IMAGE"
docker run -d --name "$NAME" \
  --shm-size=256m \
  -e POSTGRES_PASSWORD=smoke \
  -e POSTGRES_DB=app \
  -e POSTGRES_INITDB_ARGS="--locale-provider=builtin --builtin-locale=C.UTF-8" \
  -v "$VOLUME":/var/lib/postgresql \
  -v "$HERE":/tests:ro \
  "$IMAGE" >/dev/null
wait_healthy

echo "==> running smoke.sql"
docker exec "$NAME" psql -X -v ON_ERROR_STOP=1 -v pg_search="$HAS_PG_SEARCH" -v age="$HAS_AGE" -U postgres -d postgres -f /tests/smoke.sql

echo "==> checking settings"
major="$(psql_c "SELECT current_setting('server_version_num')::int / 10000")"
[[ "$(psql_c 'SHOW config_file')" == "/etc/postgresql/postgresql.conf" ]] || { echo "config_file not used" >&2; exit 1; }
[[ "$(psql_c 'SHOW jit')" == "off" ]] || { echo "jit should be off" >&2; exit 1; }
[[ "$(psql_c "SELECT datlocprovider FROM pg_database WHERE datname = 'app'")" == "b" ]] \
  || { echo "builtin locale provider not applied" >&2; exit 1; }
[[ "$(psql_c 'SHOW track_wal_io_timing')" == "on" ]] || { echo "track_wal_io_timing should be on" >&2; exit 1; }
[[ "$(psql_c 'SHOW track_activity_query_size')" == "4kB" ]] || { echo "track_activity_query_size should be 4kB" >&2; exit 1; }
if (( major >= 18 )); then
  [[ "$(psql_c 'SHOW io_method')" == "worker" ]] || { echo "io_method should be worker" >&2; exit 1; }
  [[ "$(psql_c 'SHOW data_checksums')" == "on" ]] || { echo "data checksums should be on" >&2; exit 1; }
  [[ "$(psql_c 'SHOW log_connections')" == "setup_durations" ]] || { echo "log_connections should be setup_durations" >&2; exit 1; }
  [[ "$(psql_c 'SHOW track_cost_delay_timing')" == "on" ]] || { echo "track_cost_delay_timing should be on" >&2; exit 1; }
else
  [[ "$(psql_c 'SHOW log_connections')" == "off" ]] || { echo "log_connections should be off before 18" >&2; exit 1; }
fi

if [[ -n "$EXPECTED_PGVECTOR" ]]; then
  actual="$(psql_c "SELECT default_version FROM pg_available_extensions WHERE name = 'vector'")"
  [[ "$actual" == "$EXPECTED_PGVECTOR" ]] || { echo "pgvector $actual != expected $EXPECTED_PGVECTOR" >&2; exit 1; }
fi

actual="$(psql_c "SELECT coalesce(max(default_version), '') FROM pg_available_extensions WHERE name = 'pg_search'")"
[[ "$actual" == "$EXPECTED_PG_SEARCH" ]] \
  || { echo "pg_search '$actual' != expected '$EXPECTED_PG_SEARCH'" >&2; exit 1; }

actual="$(psql_c "SELECT count(*) FROM pg_available_extensions WHERE name = 'age'")"
[[ "$actual" == "$HAS_AGE" ]] || { echo "age available: $actual, expected $HAS_AGE" >&2; exit 1; }
# AGE must stay out of the preload lists: only databases that use it load it.
[[ "$(psql_c "SELECT (current_setting('shared_preload_libraries') || ',' || current_setting('session_preload_libraries')) ~ '(^|,)\s*age\s*(,|$)'")" == "f" ]] \
  || { echo "age must not be preloaded" >&2; exit 1; }

echo "==> image manifest"
docker exec "$NAME" cat /usr/share/evilflowers/manifest.txt

echo "==> restart on existing data directory"
docker restart "$NAME" >/dev/null
wait_healthy
psql_c "SELECT count(*) FROM pg_extension WHERE extname = 'pg_cron'" | grep -qx 1

echo "==> PASS: $IMAGE"
