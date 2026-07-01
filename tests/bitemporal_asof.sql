-- Tests for Primitive 4 — bitemporal as-of queries.
-- Requires engine/*.sql applied.

SET client_min_messages = 'notice';
BEGIN;
TRUNCATE kndb.fact, kndb_audit.evicted_fact, kndb.slot_kind, kndb.conflict_policy CASCADE;

-- Timeline: patient 20 was believed non-diabetic 2020-2022, then diabetic 2022+.
INSERT INTO kndb.fact (entity_id, attribute, value, epistemic_kind, confidence, valid_time) VALUES
  (20, 'is_diabetic', 'false', 'inference', 0.85, tstzrange('2020-01-01', '2022-01-01', '[)')),
  (20, 'is_diabetic', 'true',  'inference', 0.90, tstzrange('2022-01-01', 'infinity', '[)'));

\echo '-- T4.1 as_of_valid returns the row whose valid_time contains the query point'
DO $$
DECLARE v text;
BEGIN
  SELECT value INTO v FROM kndb.as_of_valid(20, 'is_diabetic', '2021-06-15'::timestamptz);
  IF v <> 'false' THEN RAISE EXCEPTION 'FAIL T4.1a: expected false, got %', v; END IF;

  SELECT value INTO v FROM kndb.as_of_valid(20, 'is_diabetic', '2023-06-15'::timestamptz);
  IF v <> 'true'  THEN RAISE EXCEPTION 'FAIL T4.1b: expected true, got %',  v; END IF;

  RAISE NOTICE 'PASS T4.1: as_of_valid returns correct historical belief';
END $$;

\echo '-- T4.2 as_of_believed with a future sys_time still sees the row'
DO $$
DECLARE v text;
BEGIN
  SELECT value INTO v FROM kndb.as_of_believed(20, 'is_diabetic', '2023-06-15', now() + interval '1 day');
  IF v <> 'true' THEN RAISE EXCEPTION 'FAIL T4.2: expected true, got %', v; END IF;
  RAISE NOTICE 'PASS T4.2: as_of_believed correct for future sys_time';
END $$;

ROLLBACK;
\echo '== bitemporal_asof: all sub-tests PASS =='
