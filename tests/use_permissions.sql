-- Tests for Primitive 6 — use-permission scope views.
-- fact_compliance   : MEASURED + DERIVED, live rows only.
-- fact_analytics    : all kinds, live rows only.
-- fact_training_safe: MEASURED only, live rows only.
-- Requires engine/*.sql applied.

SET client_min_messages = 'notice';
BEGIN;
TRUNCATE kndb.fact, kndb_audit.evicted_fact, kndb.slot_kind, kndb.conflict_policy CASCADE;

-- Seed rows spanning all three kinds for the same entity.
INSERT INTO kndb.fact (entity_id, attribute, value, epistemic_kind, confidence, valid_time) VALUES
  (100, 'weight_kg',   '80',   'MEASURED', 0.95, tstzrange('2026-01-01', 'infinity', '[)')),
  (100, 'is_diabetic', 'true', 'INFERRED', 0.70, tstzrange('2026-01-01', 'infinity', '[)'));

INSERT INTO kndb.fact (entity_id, attribute, value, epistemic_kind, confidence, sources, valid_time)
SELECT 100, 'avg_weight_90d', '80', 'DERIVED', 0.85,
       ARRAY(SELECT fact_id FROM kndb.fact WHERE entity_id=100 AND attribute='weight_kg'),
       tstzrange('2026-01-01', 'infinity', '[)');

\echo '-- T6.1 fact_compliance excludes INFERRED, includes MEASURED and DERIVED'
DO $$
DECLARE
  n_total    int;
  n_measured int;
  n_derived  int;
  n_inferred int;
BEGIN
  SELECT count(*) INTO n_total
    FROM kndb.fact_compliance WHERE entity_id = 100;
  SELECT count(*) INTO n_measured
    FROM kndb.fact_compliance WHERE entity_id = 100 AND epistemic_kind = 'MEASURED';
  SELECT count(*) INTO n_derived
    FROM kndb.fact_compliance WHERE entity_id = 100 AND epistemic_kind = 'DERIVED';
  SELECT count(*) INTO n_inferred
    FROM kndb.fact_compliance WHERE entity_id = 100 AND epistemic_kind = 'INFERRED';

  IF n_inferred <> 0 THEN
    RAISE EXCEPTION 'FAIL T6.1: fact_compliance included INFERRED rows (%)', n_inferred;
  END IF;
  IF n_measured <> 1 THEN
    RAISE EXCEPTION 'FAIL T6.1: fact_compliance expected 1 MEASURED, got %', n_measured;
  END IF;
  IF n_derived <> 1 THEN
    RAISE EXCEPTION 'FAIL T6.1: fact_compliance expected 1 DERIVED, got %', n_derived;
  END IF;
  IF n_total <> 2 THEN
    RAISE EXCEPTION 'FAIL T6.1: fact_compliance expected total 2, got %', n_total;
  END IF;
  RAISE NOTICE 'PASS T6.1: fact_compliance = MEASURED(%) + DERIVED(%) = %',
    n_measured, n_derived, n_total;
END $$;

\echo '-- T6.2 fact_analytics includes all three kinds'
DO $$
DECLARE
  n_total    int;
  n_measured int;
  n_inferred int;
  n_derived  int;
BEGIN
  SELECT count(*) INTO n_total
    FROM kndb.fact_analytics WHERE entity_id = 100;
  SELECT count(*) INTO n_measured
    FROM kndb.fact_analytics WHERE entity_id = 100 AND epistemic_kind = 'MEASURED';
  SELECT count(*) INTO n_inferred
    FROM kndb.fact_analytics WHERE entity_id = 100 AND epistemic_kind = 'INFERRED';
  SELECT count(*) INTO n_derived
    FROM kndb.fact_analytics WHERE entity_id = 100 AND epistemic_kind = 'DERIVED';

  IF n_total <> 3 THEN
    RAISE EXCEPTION 'FAIL T6.2: fact_analytics expected 3, got %', n_total;
  END IF;
  IF n_measured <> 1 OR n_inferred <> 1 OR n_derived <> 1 THEN
    RAISE EXCEPTION 'FAIL T6.2: fact_analytics kind breakdown wrong: MEASURED=%, INFERRED=%, DERIVED=%',
      n_measured, n_inferred, n_derived;
  END IF;
  RAISE NOTICE 'PASS T6.2: fact_analytics = MEASURED(%) + INFERRED(%) + DERIVED(%) = %',
    n_measured, n_inferred, n_derived, n_total;
END $$;

\echo '-- T6.3 fact_training_safe includes only MEASURED'
DO $$
DECLARE
  n_total     int;
  n_non_meas  int;
BEGIN
  SELECT count(*) INTO n_total
    FROM kndb.fact_training_safe WHERE entity_id = 100;
  SELECT count(*) INTO n_non_meas
    FROM kndb.fact_training_safe WHERE entity_id = 100 AND epistemic_kind <> 'MEASURED';

  IF n_total <> 1 THEN
    RAISE EXCEPTION 'FAIL T6.3: fact_training_safe expected 1 row, got %', n_total;
  END IF;
  IF n_non_meas <> 0 THEN
    RAISE EXCEPTION 'FAIL T6.3: fact_training_safe contained non-MEASURED rows (%)', n_non_meas;
  END IF;
  RAISE NOTICE 'PASS T6.3: fact_training_safe = MEASURED-only, count = %', n_total;
END $$;

ROLLBACK;
\echo '== use_permissions: all sub-tests PASS =='
