-- Smoke test executed by tests/smoke.sh inside the container.
-- Any error aborts the run (psql -v ON_ERROR_STOP=1).

\echo '== server'
SELECT version();
SHOW config_file;
SHOW shared_preload_libraries;
SHOW jit;

\echo '== preloaded libraries are active'
DO $$
DECLARE lib text;
BEGIN
  FOREACH lib IN ARRAY ARRAY['pg_stat_statements', 'auto_explain', 'pg_cron', 'pgaudit'] LOOP
    IF position(lib IN current_setting('shared_preload_libraries')) = 0 THEN
      RAISE EXCEPTION 'library % is not preloaded', lib;
    END IF;
  END LOOP;
END $$;

\echo '== initdb hook created extensions'
SELECT extname, extversion FROM pg_extension ORDER BY extname;
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    RAISE EXCEPTION 'pg_cron missing in postgres database';
  END IF;
END $$;

\echo '== every bundled extension can be created'
CREATE DATABASE smoke;
\connect smoke
CREATE EXTENSION vector;
CREATE EXTENSION hypopg;
CREATE EXTENSION pg_repack;
CREATE EXTENSION pgaudit;
CREATE SCHEMA partman;
CREATE EXTENSION pg_partman SCHEMA partman;
CREATE EXTENSION pg_trgm;
CREATE EXTENSION unaccent;
CREATE EXTENSION btree_gin;
SELECT extname, extversion FROM pg_extension ORDER BY extname;

\echo '== pg_stat_statements inherited from template1'
SELECT count(*) >= 0 AS ok FROM pg_stat_statements;

\echo '== pgvector: HNSW index build and k-NN query'
CREATE TABLE items (id bigserial PRIMARY KEY, embedding vector(3));
INSERT INTO items (embedding)
SELECT ARRAY[random(), random(), random()]::vector(3) FROM generate_series(1, 5000);
INSERT INTO items (embedding) VALUES ('[1,1,1]');
SET maintenance_work_mem = '128MB';
CREATE INDEX ON items USING hnsw (embedding vector_cosine_ops);
CREATE INDEX ON items USING ivfflat (embedding vector_l2_ops) WITH (lists = 10);
ANALYZE items;
SET enable_seqscan = off;
DO $$
DECLARE
  line text;
  plan text := '';
BEGIN
  FOR line IN EXECUTE 'EXPLAIN SELECT id FROM items ORDER BY embedding <=> ''[1,1,1]'' LIMIT 5' LOOP
    plan := plan || line || E'\n';
  END LOOP;
  IF plan NOT LIKE '%Index Scan using items_embedding_idx %' THEN
    RAISE EXCEPTION 'HNSW index not used: %', plan;
  END IF;
END $$;
SELECT id, embedding <-> '[1,1,1]' AS distance FROM items ORDER BY embedding <-> '[1,1,1]' LIMIT 3;
SELECT '[1,2,3]'::halfvec(3) AS halfvec, '{1:1,3:2}/3'::sparsevec AS sparsevec;
RESET enable_seqscan;

\echo '== pg_trgm + unaccent'
SELECT similarity(unaccent('Žltý kôň'), 'Zlty kon') > 0.5 AS trgm_ok;

\echo '== hypopg'
SELECT count(*) = 1 AS hypopg_ok FROM hypopg_create_index('CREATE INDEX ON items (id)');

\connect postgres
\echo '== pg_cron'
SELECT cron.schedule_in_database('smoke-job', '*/5 * * * *', 'SELECT 1', 'smoke') > 0 AS scheduled;
SELECT cron.unschedule('smoke-job');
DROP DATABASE smoke WITH (FORCE);

\echo 'SMOKE OK'
