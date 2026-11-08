-- Smoke test executed by tests/smoke.sh inside the container.
-- Any error aborts the run (psql -v ON_ERROR_STOP=1).
-- smoke.sh sets :pg_search to 1 when the image ships pg_search, else 0.

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
\if :pg_search
SELECT position('pg_search' IN current_setting('shared_preload_libraries')) > 0 AS pg_search_preloaded \gset
\if :pg_search_preloaded
\else
\echo 'pg_search is not preloaded'
SELECT 1/0;
\endif
\endif

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

\echo '== Slovak and Czech hunspell dictionaries (the setup documented in README.md)'
CREATE TEXT SEARCH DICTIONARY slovak_hunspell (TEMPLATE = ispell, DictFile = sk_sk, AffFile = sk_sk, StopWords = slovak);
CREATE TEXT SEARCH DICTIONARY slovak_stop (TEMPLATE = simple, StopWords = slovak, Accept = false);
CREATE TEXT SEARCH CONFIGURATION slovak (COPY = simple);
ALTER TEXT SEARCH CONFIGURATION slovak
  ALTER MAPPING FOR asciiword, word, hword, hword_part WITH slovak_stop, slovak_hunspell, simple;
CREATE TEXT SEARCH DICTIONARY czech_hunspell (TEMPLATE = ispell, DictFile = cs_cz, AffFile = cs_cz, StopWords = czech);
CREATE TEXT SEARCH DICTIONARY czech_stop (TEMPLATE = simple, StopWords = czech, Accept = false);
CREATE TEXT SEARCH CONFIGURATION czech (COPY = simple);
ALTER TEXT SEARCH CONFIGURATION czech
  ALTER MAPPING FOR asciiword, word, hword, hword_part WITH czech_stop, czech_hunspell, simple;
SELECT to_tsvector('slovak', 'Vzdelávanie v knižniciach') AS slovak, to_tsvector('czech', 'Kniha nebo časopis o knihovnách') AS czech;
DO $$
DECLARE
  t text[];
BEGIN
  -- dictionary, inflected form, expected lemma
  FOREACH t SLICE 1 IN ARRAY ARRAY[
    ['slovak_hunspell', 'vzdelávania', 'vzdelávanie'],
    ['slovak_hunspell', 'knižniciach', 'knižnica'],
    ['slovak_hunspell', 'univerzite', 'univerzita'],
    ['czech_hunspell', 'vzdělávacích', 'vzdělávací'],
    ['czech_hunspell', 'knihovnách', 'knihovna'],
    ['czech_hunspell', 'univerzitě', 'univerzita']
  ] LOOP
    IF NOT coalesce(ts_lexize(t[1]::regdictionary, t[2]) @> ARRAY[t[3]], false) THEN
      RAISE EXCEPTION '%: % lexized to %, expected %', t[1], t[2], ts_lexize(t[1]::regdictionary, t[2]), t[3];
    END IF;
  END LOOP;
  -- stop lists are loaded and the stop dictionary catches words whose lemma is
  -- not in the list (Czech "nebo" lemmatizes to {ba,ben})
  IF to_tsvector('czech', 'nebo a v') <> ''::tsvector OR to_tsvector('slovak', 'je a v') <> ''::tsvector THEN
    RAISE EXCEPTION 'stop words not removed';
  END IF;
  IF NOT to_tsvector('slovak', 'Vzdelávanie v knižniciach') @@ to_tsquery('slovak', 'vzdelávania & knižnica')
     OR NOT to_tsvector('czech', 'Vzdělávání v knihovnách') @@ to_tsquery('czech', 'knihovna') THEN
    RAISE EXCEPTION 'inflected forms do not match';
  END IF;
END $$;

\if :pg_search
\echo '== pg_search: BM25 index, ranked query, hybrid with pgvector'
CREATE EXTENSION pg_search;
CREATE TABLE docs (id int PRIMARY KEY, body text, embedding vector(3));
INSERT INTO docs VALUES
  (1, 'Žltý kôň skáče cez plot', '[1,0,0]'),
  (2, 'Kôň, kôň a ešte raz kôň', '[0,1,0]'),
  (3, 'Vektorové vyhľadávanie v PostgreSQL', '[0,0,1]');
INSERT INTO docs SELECT i, 'filler document ' || i, '[0.5,0.5,0.5]' FROM generate_series(4, 500) AS i;
CREATE INDEX docs_bm25_idx ON docs USING bm25 (id, body);
SET enable_seqscan = off;
DO $$
DECLARE
  line text;
  plan text := '';
BEGIN
  FOR line IN EXECUTE 'EXPLAIN SELECT id FROM docs WHERE body ||| ''kôň''' LOOP
    plan := plan || line || E'\n';
  END LOOP;
  IF plan NOT LIKE '%docs_bm25_idx%' THEN
    RAISE EXCEPTION 'BM25 index not used: %', plan;
  END IF;
END $$;
RESET enable_seqscan;
-- BM25: the document repeating the term ranks first; filler never matches.
SELECT id, pdb.score(id) AS score FROM docs WHERE body ||| 'kôň' ORDER BY score DESC;
DO $$
BEGIN
  IF ARRAY(SELECT id FROM docs WHERE body ||| 'kôň' ORDER BY pdb.score(id) DESC) <> ARRAY[2, 1] THEN
    RAISE EXCEPTION 'unexpected BM25 ranking';
  END IF;
END $$;
-- Reciprocal rank fusion of the lexical and dense branches, as one query.
WITH lexical AS (
  SELECT id, rank() OVER (ORDER BY pdb.score(id) DESC) AS r FROM docs WHERE body ||| 'kôň' LIMIT 20
), dense AS (
  SELECT id, rank() OVER (ORDER BY embedding <=> '[1,0,0]') AS r FROM docs ORDER BY embedding <=> '[1,0,0]' LIMIT 20
)
SELECT id, sum(1.0 / (60 + r)) AS rrf
FROM (SELECT * FROM lexical UNION ALL SELECT * FROM dense) AS fused
GROUP BY id ORDER BY rrf DESC LIMIT 3;
\endif

\echo '== hypopg'
SELECT count(*) = 1 AS hypopg_ok FROM hypopg_create_index('CREATE INDEX ON items (id)');

\connect postgres
\echo '== pg_cron'
SELECT cron.schedule_in_database('smoke-job', '*/5 * * * *', 'SELECT 1', 'smoke') > 0 AS scheduled;
SELECT cron.unschedule('smoke-job');
DROP DATABASE smoke WITH (FORCE);

\echo 'SMOKE OK'
