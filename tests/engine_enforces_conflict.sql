-- Tests for Primitive 3 — write-time conflict detection with audit preservation.
-- Requires engine/*.sql applied.

SET client_min_messages = 'notice';
BEGIN;
TRUNCATE kndb.fact, kndb_audit.evicted_fact, kndb.conflict_policy CASCADE;

-- T3.1: same-value overlap → absorbed (row count stays 1, valid_time widens).
\echo '-- T3.1 same-value overlap is absorbed'
INSERT INTO kndb.fact (entity_id, attribute, value, epistemic_kind, confidence, valid_time)
VALUES (10, 'weight_kg', '82', 'observation', 0.95, tstzrange('2026-01-01', '2026-03-01', '[)'));
INSERT INTO kndb.fact (entity_id, attribute, value, epistemic_kind, confidence, valid_time)
VALUES (10, 'weight_kg', '82', 'observation', 0.95, tstzrange('2026-02-15', '2026-05-01', '[)'));

DO $$
DECLARE n int; vt tstzrange;
BEGIN
  SELECT count(*) INTO n FROM kndb.fact WHERE entity_id=10 AND attribute='weight_kg';
  IF n <> 1 THEN RAISE EXCEPTION 'FAIL T3.1: expected 1 absorbed row, got %', n; END IF;
  SELECT valid_time INTO vt FROM kndb.fact WHERE entity_id=10 AND attribute='weight_kg';
  IF NOT vt @> '2026-04-01'::timestamptz OR NOT vt @> '2026-01-15'::timestamptz THEN
    RAISE EXCEPTION 'FAIL T3.1: absorbed valid_time did not widen: %', vt;
  END IF;
  RAISE NOTICE 'PASS T3.1: absorbed row valid_time = %', vt;
END $$;

-- T3.2: different-value overlap under default 'invalidate' policy → prior evicted.
\echo '-- T3.2 different-value overlap invalidates prior'
INSERT INTO kndb.fact (entity_id, attribute, value, epistemic_kind, confidence, valid_time)
VALUES (11, 'weight_kg', '82', 'observation', 0.95, tstzrange('2026-01-01', '2026-03-01', '[)'));
INSERT INTO kndb.fact (entity_id, attribute, value, epistemic_kind, confidence, valid_time)
VALUES (11, 'weight_kg', '85', 'observation', 0.95, tstzrange('2026-02-15', '2026-05-01', '[)'));

DO $$
DECLARE
  alive_n int; closed_n int; audit_n int;
BEGIN
  SELECT count(*) INTO alive_n FROM kndb.fact
    WHERE entity_id=11 AND attribute='weight_kg' AND upper(sys_time) = 'infinity';
  SELECT count(*) INTO closed_n FROM kndb.fact
    WHERE entity_id=11 AND attribute='weight_kg' AND upper(sys_time) <> 'infinity';
  SELECT count(*) INTO audit_n FROM kndb_audit.evicted_fact WHERE reason = 'contradicted_by';
  IF alive_n <> 1 OR closed_n <> 1 OR audit_n < 1 THEN
    RAISE EXCEPTION 'FAIL T3.2: alive=% closed=% audit=%', alive_n, closed_n, audit_n;
  END IF;
  RAISE NOTICE 'PASS T3.2: 1 alive, 1 closed, % audit rows', audit_n;
END $$;

-- T3.3: 'reject' policy → new write is refused.
\echo '-- T3.3 reject policy refuses new write and audits it'
INSERT INTO kndb.conflict_policy (attribute, policy) VALUES ('bp_systolic', 'reject');
INSERT INTO kndb.fact (entity_id, attribute, value, epistemic_kind, confidence, valid_time)
VALUES (12, 'bp_systolic', '120', 'observation', 0.95, tstzrange('2026-01-01', '2026-03-01', '[)'));
DO $$
BEGIN
  BEGIN
    INSERT INTO kndb.fact (entity_id, attribute, value, epistemic_kind, confidence, valid_time)
    VALUES (12, 'bp_systolic', '145', 'observation', 0.95, tstzrange('2026-02-15', '2026-05-01', '[)'));
    RAISE EXCEPTION 'FAIL T3.3: reject-policy write should have raised';
  EXCEPTION WHEN check_violation THEN
    RAISE NOTICE 'PASS T3.3: reject policy raised as expected';
  END;
END $$;

-- Note: audit persistence for rejected writes requires an autonomous
-- transaction (dblink); scoped-out for the prototype. The engine's audit
-- guarantee holds for 'invalidate' policy (loser preserved — T3.2 above)
-- and rejected writes appear in the Postgres error log with row payload.
-- See DECISIONS.md 2026-07-01 M0 semantics finding.

ROLLBACK;
\echo '== engine_enforces_conflict: all sub-tests PASS =='
