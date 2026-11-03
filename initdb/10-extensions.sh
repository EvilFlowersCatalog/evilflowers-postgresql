#!/usr/bin/env bash
# Runs once, on first initialisation of an empty data directory
# (sourced by docker-entrypoint.sh; not used by CloudNativePG).
#
# - pg_stat_statements in template1, so every new database gets it
# - pg_cron in the "postgres" database (cron.database_name); schedule jobs for
#   other databases with cron.schedule_in_database()
#
# Application extensions (vector, pg_trgm, unaccent, ...) are created by the
# applications' own migrations, e.g. CREATE EXTENSION IF NOT EXISTS vector;
set -Eeuo pipefail

psql_as_super() {
  psql -v ON_ERROR_STOP=1 --no-psqlrc --username "${POSTGRES_USER:-postgres}" "$@"
}

psql_as_super --dbname template1 <<'SQL'
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
SQL

psql_as_super --dbname postgres <<'SQL'
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
CREATE EXTENSION IF NOT EXISTS pg_cron;
SQL

# POSTGRES_DB was created before this script ran, from the old template1.
if [[ -n "${POSTGRES_DB:-}" && "${POSTGRES_DB}" != "postgres" ]]; then
  psql_as_super --dbname "${POSTGRES_DB}" <<'SQL'
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
SQL
fi
