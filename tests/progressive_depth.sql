-- Tests for Primitive 5 — progressive-depth expand().
-- Monotonicity: recall(d+1) ≥ recall(d), avg_conf(d+1) ≤ avg_conf(d).
-- Requires engine/*.sql applied.

SET client_min_messages = 'notice';
BEGIN;
TRUNCATE kndb.fact, kndb_audit.evicted_fact, kndb.slot_kind, kndb.conflict_policy CASCADE;

-- One patient with mixed obs / inference / derived.
INSERT INTO kndb.fact (entity_id, attribute, value, epistemic_kind, confidence, valid_time) VALUES
  (30, 'hba1c',       '7.2',   'MEASURED', 0.95, tstzrange('2026-01-01', 'infinity', '[)')),
  (30, 'ldl',         '112',   'MEASURED', 0.95, tstzrange('2026-01-01', 'infinity', '[)')),
  (30, 'bp_systolic', '138',   'MEASURED', 0.95, tstzrange('2026-01-01', 'infinity', '[)')),
  (30, 'is_diabetic', 'true',  'INFERRED',   0.72, tstzrange('2026-01-01', 'infinity', '[)')),
  (30, 'is_hypertensive','true','INFERRED', 0.60, tstzrange('2026-01-01', 'infinity', '[)'));

-- derived requires sources; grab the obs UUIDs.
INSERT INTO kndb.fact (entity_id, attribute, value, epistemic_kind, confidence, sources, valid_time)
SELECT 30, 'avg_bp_systolic_90d', '138', 'DERIVED', 0.80,
       ARRAY(SELECT fact_id FROM kndb.fact WHERE entity_id=30 AND attribute='bp_systolic'),
       tstzrange('2026-01-01', 'infinity', '[)');

\echo '-- T5.1 recall is monotone non-decreasing in depth'
DO $$
DECLARE
  r0 int; r1 int; r2 int;
  a0 numeric; a1 numeric; a2 numeric;
BEGIN
  SELECT count(*), avg(confidence) INTO r0, a0 FROM kndb.expand(30, 0);
  SELECT count(*), avg(confidence) INTO r1, a1 FROM kndb.expand(30, 1);
  SELECT count(*), avg(confidence) INTO r2, a2 FROM kndb.expand(30, 2);

  IF NOT (r0 <= r1 AND r1 <= r2) THEN
    RAISE EXCEPTION 'FAIL T5.1: recall not monotone: r0=%, r1=%, r2=%', r0, r1, r2;
  END IF;
  IF NOT (a0 >= a1 AND a1 >= a2) THEN
    RAISE EXCEPTION 'FAIL T5.1: avg conf not monotone: a0=%, a1=%, a2=%', a0, a1, a2;
  END IF;
  RAISE NOTICE 'PASS T5.1: recall %-%-% avg-conf %-%-%', r0, r1, r2, a0, a1, a2;
END $$;

ROLLBACK;
\echo '== progressive_depth: all sub-tests PASS =='
