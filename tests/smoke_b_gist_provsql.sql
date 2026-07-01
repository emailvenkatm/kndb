-- M0 smoke test B: tstzrange + GiST EXCLUDE + ProvSQL provsql column.
--
-- Question: does ProvSQL's add_provenance() (which adds a hidden `provsql uuid`
-- column) interfere with a GiST exclusion constraint enforcing no-overlap on
-- tstzrange? This gates KNDB primitive 4 (bitemporal).

\set ECHO all
\set ON_ERROR_STOP on

DROP SCHEMA IF EXISTS smoke_b CASCADE;
CREATE SCHEMA smoke_b;
SET search_path = smoke_b, public, provsql;

CREATE EXTENSION IF NOT EXISTS btree_gist;

CREATE TABLE facts (
  fact_id     int         GENERATED ALWAYS AS IDENTITY,
  entity_id   int         NOT NULL,
  attribute   text        NOT NULL,
  value       text        NOT NULL,
  valid_time  tstzrange   NOT NULL,
  PRIMARY KEY (fact_id),
  EXCLUDE USING gist (entity_id WITH =, attribute WITH =, valid_time WITH &&)
);

INSERT INTO facts (entity_id, attribute, value, valid_time) VALUES
  (1, 'diabetic', 'true',  tstzrange('2020-01-01', '2022-01-01', '[)')),
  (1, 'diabetic', 'false', tstzrange('2022-01-01', '2024-01-01', '[)'));

DO $$
BEGIN
  INSERT INTO facts (entity_id, attribute, value, valid_time)
  VALUES (1, 'diabetic', 'true', tstzrange('2021-06-01', '2023-06-01', '[)'));
  RAISE EXCEPTION 'FAIL T-B1: overlapping insert should have been rejected';
EXCEPTION WHEN exclusion_violation THEN
  RAISE NOTICE 'PASS T-B1: exclusion_violation raised before add_provenance';
END $$;

-- Activate provsql on the table (regclass cast REQUIRED in v1.10.0).
SELECT add_provenance('smoke_b.facts'::regclass);

SELECT column_name, data_type FROM information_schema.columns
 WHERE table_schema='smoke_b' AND table_name='facts' ORDER BY ordinal_position;

DO $$
DECLARE has_provsql int;
BEGIN
  SELECT count(*) INTO has_provsql
  FROM information_schema.columns
  WHERE table_schema='smoke_b' AND table_name='facts' AND column_name='provsql';
  IF has_provsql = 0 THEN
    RAISE EXCEPTION 'FAIL T-B2: add_provenance did not add provsql column';
  END IF;
  RAISE NOTICE 'PASS T-B2: provsql UUID column added';
END $$;

INSERT INTO facts (entity_id, attribute, value, valid_time) VALUES
  (1, 'diabetic', 'true', tstzrange('2024-01-01', '2025-01-01', '[)'));

DO $$
BEGIN
  INSERT INTO facts (entity_id, attribute, value, valid_time)
  VALUES (1, 'diabetic', 'false', tstzrange('2023-06-01', '2024-06-01', '[)'));
  RAISE EXCEPTION 'FAIL T-B3: overlapping insert AFTER add_provenance should still be rejected';
EXCEPTION WHEN exclusion_violation THEN
  RAISE NOTICE 'PASS T-B3: exclusion_violation still raised after add_provenance';
END $$;

-- T-B4: sanity — the provsql column is populated by INSERT (auto-token).
DO $$
DECLARE null_toks int;
BEGIN
  SELECT count(*) INTO null_toks FROM facts WHERE provsql IS NULL;
  IF null_toks > 0 THEN
    RAISE EXCEPTION 'FAIL T-B4: % rows have NULL provsql token', null_toks;
  END IF;
  RAISE NOTICE 'PASS T-B4: all rows have provsql tokens';
END $$;

DROP SCHEMA smoke_b CASCADE;
\echo '== smoke B: PASS (GiST EXCLUDE compatible with ProvSQL provsql column) =='
