-- M0 smoke test B: tstzrange + GiST EXCLUDE + ProvSQL provsql column.
--
-- Question: does ProvSQL's hidden `provsql` UUID column (added by
-- add_provenance()) interfere with a GiST exclusion constraint enforcing
-- no-overlap on tstzrange? This gates KNDB primitive 4 (bitemporal).
-- If it does, we need to reorder DDL, use partial indexes, or move
-- bitemporal enforcement to a trigger.
--
-- Run: make smoke-b

\echo '== smoke B: create schema =='
DROP SCHEMA IF EXISTS smoke_b CASCADE;
CREATE SCHEMA smoke_b;
SET search_path = smoke_b, public;

CREATE EXTENSION IF NOT EXISTS provsql CASCADE;
CREATE EXTENSION IF NOT EXISTS btree_gist;   -- required for GiST on scalar + range

CREATE TABLE facts (
  fact_id     int         GENERATED ALWAYS AS IDENTITY,
  entity_id   int         NOT NULL,
  attribute   text        NOT NULL,
  value       text        NOT NULL,
  valid_time  tstzrange   NOT NULL,
  PRIMARY KEY (fact_id),
  EXCLUDE USING gist (entity_id WITH =, attribute WITH =, valid_time WITH &&)
);

\echo '== insert non-overlapping rows (should succeed) =='
INSERT INTO facts (entity_id, attribute, value, valid_time) VALUES
  (1, 'diabetic', 'true',  tstzrange('2020-01-01', '2022-01-01', '[)')),
  (1, 'diabetic', 'false', tstzrange('2022-01-01', '2024-01-01', '[)'));

\echo '== try overlapping row (must fail with exclusion violation) =='
DO $$
BEGIN
  INSERT INTO facts (entity_id, attribute, value, valid_time)
  VALUES (1, 'diabetic', 'true', tstzrange('2021-06-01', '2023-06-01', '[)'));
  RAISE EXCEPTION 'FAIL: overlapping insert should have been rejected';
EXCEPTION
  WHEN exclusion_violation THEN
    RAISE NOTICE 'OK: exclusion_violation raised on pre-ProvSQL overlap insert';
END $$;

\echo '== now activate provsql on the table =='
SELECT add_provenance('smoke_b.facts');

\echo '== show columns to confirm provsql UUID column added =='
SELECT column_name, data_type FROM information_schema.columns
  WHERE table_schema='smoke_b' AND table_name='facts' ORDER BY ordinal_position;

\echo '== insert non-overlapping row after add_provenance (should still succeed) =='
INSERT INTO facts (entity_id, attribute, value, valid_time) VALUES
  (1, 'diabetic', 'true', tstzrange('2024-01-01', '2025-01-01', '[)'));

\echo '== overlapping row after add_provenance (must STILL fail — the guarantee we care about) =='
DO $$
BEGIN
  INSERT INTO facts (entity_id, attribute, value, valid_time)
  VALUES (1, 'diabetic', 'false', tstzrange('2023-06-01', '2024-06-01', '[)'));
  RAISE EXCEPTION 'FAIL: overlapping insert AFTER add_provenance should still be rejected';
EXCEPTION
  WHEN exclusion_violation THEN
    RAISE NOTICE 'OK: exclusion_violation still raised after add_provenance';
END $$;

DROP SCHEMA smoke_b CASCADE;
\echo '== smoke B complete =='
