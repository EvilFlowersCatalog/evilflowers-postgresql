-- Smoke test executed by tests/smoke.sh inside the container.
-- Any error aborts the run (psql -v ON_ERROR_STOP=1).
-- smoke.sh sets :pg_search to 1 when the image ships pg_search, else 0, and
-- :age likewise for Apache AGE.

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

\if :age
-- Same session as the pgvector and pg_search blocks above, so the three
-- extensions are proven to coexist in one backend.
\echo '== Apache AGE: graph, Cypher, join with relational data'
CREATE EXTENSION age;
LOAD 'age';
-- Schema-qualifying ag_catalog.cypher is not enough: create_graph, label
-- creation and edge matches resolve AGE's graphid operators through
-- search_path. Appending ag_catalog keeps it from shadowing public.
SET search_path = "$user", public, ag_catalog;
SELECT ag_catalog.create_graph('smoke_graph');
SELECT * FROM ag_catalog.cypher('smoke_graph', $$
  CREATE (:Section {id: 1})-[:DEFINES]->(:Concept {term: 'entropia'})<-[:DISCUSSES]-(:Section {id: 2})
$$) AS (v ag_catalog.agtype);
SELECT coalesce(string_agg(format('%s->%s', a, b), ','), '') = '1->2' AS age_path_ok
FROM ag_catalog.cypher('smoke_graph', $$
  MATCH (a:Section)-[:DEFINES]->(c:Concept)<-[:DISCUSSES]-(b:Section) RETURN a.id, b.id
$$) AS (a ag_catalog.agtype, b ag_catalog.agtype) \gset
\if :age_path_ok
\else
\echo 'Cypher did not return exactly the path 1 -> 2'
SELECT 1/0;
\endif
-- Graph result joined with the pgvector table (and the pg_search table).
DO $$
DECLARE
  n int;
BEGIN
  SELECT count(*) INTO n
  FROM ag_catalog.cypher('smoke_graph', $c$
    MATCH (s:Section)-[:DISCUSSES]->(:Concept {term: 'entropia'}) RETURN s.id
  $c$) AS g (sid ag_catalog.agtype)
  JOIN items ON items.id = g.sid::text::bigint
  WHERE items.embedding IS NOT NULL;
  IF n <> 1 THEN
    RAISE EXCEPTION 'graph/pgvector join returned % rows, expected 1', n;
  END IF;
END $$;
\if :pg_search
SELECT g.sid::text::int AS section, docs.body, pdb.score(docs.id) AS score
FROM ag_catalog.cypher('smoke_graph', $$
  MATCH (s:Section)-[]->(:Concept) RETURN s.id
$$) AS g (sid ag_catalog.agtype)
JOIN docs ON docs.id = g.sid::text::int
WHERE docs.body ||| 'kôň'
ORDER BY score DESC;
DO $$
BEGIN
  IF ARRAY(
    SELECT docs.id
    FROM ag_catalog.cypher('smoke_graph', $c$
      MATCH (s:Section)-[]->(:Concept) RETURN s.id
    $c$) AS g (sid ag_catalog.agtype)
    JOIN docs ON docs.id = g.sid::text::int
    WHERE docs.body ||| 'kôň'
    ORDER BY pdb.score(docs.id) DESC
  ) <> ARRAY[2, 1] THEN
    RAISE EXCEPTION 'graph/pg_search join returned an unexpected ranking';
  END IF;
END $$;
\endif
SELECT ag_catalog.drop_graph('smoke_graph', true);

\echo '== Apache AGE as a non-superuser (the grants documented in README.md)'
-- A non-superuser may LOAD only libraries under $libdir/plugins/. These two
-- grants are the minimum: without USAGE create_graph is not found, without
-- CREATE on the database it fails with "graph name is invalid".
CREATE ROLE smoke_app LOGIN;
GRANT CREATE ON DATABASE smoke TO smoke_app;
GRANT USAGE ON SCHEMA ag_catalog TO smoke_app;
-- A fresh backend, so the library is not already loaded by the superuser above.
\connect smoke smoke_app
BEGIN;
LOAD '$libdir/plugins/age';
SET LOCAL search_path = ag_catalog, "$user", public;
SELECT create_graph('smoke_app_graph');
SELECT * FROM cypher('smoke_app_graph', $$
  CREATE (:Concept {term: 'x'})-[:MENTIONS]->(:Section)
$$) AS (v agtype);
SELECT v::text = '2' AS age_app_ok
FROM cypher('smoke_app_graph', $$ MATCH (n) RETURN count(n) $$) AS (v agtype) \gset
COMMIT;
\if :age_app_ok
\else
\echo 'Cypher as a non-superuser did not see 2 nodes'
SELECT 1/0;
\endif
-- The unrestricted name must stay refused: consumers load the plugins path.
DO $$
BEGIN
  LOAD 'age';
  RAISE EXCEPTION 'LOAD ''age'' succeeded for a non-superuser';
EXCEPTION WHEN insufficient_privilege THEN
  RAISE NOTICE 'LOAD ''age'' refused for a non-superuser, as expected';
END $$;
\connect smoke postgres
\endif

\echo '== hypopg'
SELECT count(*) = 1 AS hypopg_ok FROM hypopg_create_index('CREATE INDEX ON items (id)');

\connect postgres
\echo '== pg_cron'
SELECT cron.schedule_in_database('smoke-job', '*/5 * * * *', 'SELECT 1', 'smoke') > 0 AS scheduled;
SELECT cron.unschedule('smoke-job');
DROP DATABASE smoke WITH (FORCE);
DROP ROLE IF EXISTS smoke_app;

\echo 'SMOKE OK'
