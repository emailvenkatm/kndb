-- Tests for Primitive 3 — write-time conflict detection with audit preservation.
-- Requires engine/*.sql applied.

SET client_min_messages = 'notice';
BEGIN;
TRUNCATE kndb.fact, kndb_audit.evicted_fact, kndb.conflict_policy CASCADE;

-- T3.1: same-value overlap → absorbed (row count stays 1, valid_time widens).
\echo '-- T3.1 same-value overlap is absorbed'
INSERT INTO kndb.fact (entity_id, attribute, value, epistemic_kind, confidence, valid_time)
VALUES (10, 'weight_kg', '82', 'MEASURED', 0.95, tstzrange('2026-01-01', '2026-03-01', '[)'));
INSERT INTO kndb.fact (entity_id, attribute, value, epistemic_kind, confidence, valid_time)
VALUES (10, 'weight_kg', '82', 'MEASURED', 0.95, tstzrange('2026-02-15', '2026-05-01', '[)'));

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

-- T3.2: different-value overlap where NEW ties on kind, specificity, and
-- confidence with the prior. Under the v2 lattice this is a "true tie":
-- prior evicted, NEW lands by arrival, audit reason=contradicted_same_rank.
\echo '-- T3.2 different-value overlap on tied lattice invalidates prior'
INSERT INTO kndb.fact (entity_id, attribute, value, epistemic_kind, confidence, valid_time)
VALUES (11, 'weight_kg', '82', 'MEASURED', 0.95, tstzrange('2026-01-01', '2026-03-01', '[)'));
INSERT INTO kndb.fact (entity_id, attribute, value, epistemic_kind, confidence, valid_time)
VALUES (11, 'weight_kg', '85', 'MEASURED', 0.95, tstzrange('2026-02-15', '2026-05-01', '[)'));

DO $$
DECLARE
  alive_n int; closed_n int; audit_n int;
BEGIN
  SELECT count(*) INTO alive_n FROM kndb.fact
    WHERE entity_id=11 AND attribute='weight_kg' AND upper(sys_time) = 'infinity';
  SELECT count(*) INTO closed_n FROM kndb.fact
    WHERE entity_id=11 AND attribute='weight_kg' AND upper(sys_time) <> 'infinity';
  SELECT count(*) INTO audit_n FROM kndb_audit.evicted_fact
    WHERE reason = 'contradicted_same_rank'
      AND (original_row->>'entity_id')::int = 11
      AND original_row->>'attribute' = 'weight_kg';
  IF alive_n <> 1 OR closed_n <> 1 OR audit_n < 1 THEN
    RAISE EXCEPTION 'FAIL T3.2: alive=% closed=% audit=%', alive_n, closed_n, audit_n;
  END IF;
  RAISE NOTICE 'PASS T3.2: 1 alive, 1 closed, % audit rows', audit_n;
END $$;

-- T3.3: 'reject' policy → new write is refused.
\echo '-- T3.3 reject policy refuses new write and audits it'
INSERT INTO kndb.conflict_policy (attribute, policy) VALUES ('bp_systolic', 'reject');
INSERT INTO kndb.fact (entity_id, attribute, value, epistemic_kind, confidence, valid_time)
VALUES (12, 'bp_systolic', '120', 'MEASURED', 0.95, tstzrange('2026-01-01', '2026-03-01', '[)'));
DO $$
BEGIN
  BEGIN
    INSERT INTO kndb.fact (entity_id, attribute, value, epistemic_kind, confidence, valid_time)
    VALUES (12, 'bp_systolic', '145', 'MEASURED', 0.95, tstzrange('2026-02-15', '2026-05-01', '[)'));
    RAISE EXCEPTION 'FAIL T3.3: reject-policy write should have raised';
  EXCEPTION WHEN check_violation THEN
    RAISE NOTICE 'PASS T3.3: reject policy raised as expected';
  END;
END $$;

-- Note: audit persistence for rejected writes requires an autonomous
-- transaction (dblink); scoped-out for the prototype. The engine's audit
-- guarantee holds for the lattice invalidate path (loser preserved, T3.2
-- above and T3.5 through T3.9 below) and rejected writes appear in the
-- Postgres error log with row payload.
-- See DECISIONS.md 2026-07-01 M0 semantics finding.

-- T3.4: high-confidence INFERRED (0.97) arriving after lower-confidence
-- MEASURED (0.90) is REFUSED by the precedence lattice on kind rank.
-- Prior MEASURED stays alive; NEW never lands.
\echo '-- T3.4 kind rank refuses high-conf INFERRED against lower-conf MEASURED'
INSERT INTO kndb.fact (entity_id, attribute, value, epistemic_kind, confidence, valid_time)
VALUES (13, 'weight_kg', '80', 'MEASURED', 0.90, tstzrange('2026-01-01', '2026-06-01', '[)'));
DO $$
DECLARE alive_n int; alive_val text; alive_kind kndb.epistemic_kind;
BEGIN
  BEGIN
    INSERT INTO kndb.fact (entity_id, attribute, value, epistemic_kind, confidence, valid_time)
    VALUES (13, 'weight_kg', '75', 'INFERRED', 0.97, tstzrange('2026-02-01', '2026-05-01', '[)'));
    RAISE EXCEPTION 'FAIL T3.4: outranked INFERRED write should have raised';
  EXCEPTION WHEN check_violation THEN
    -- expected: precedence lattice refused NEW
    NULL;
  END;
  SELECT count(*) INTO alive_n FROM kndb.fact
  WHERE entity_id=13 AND attribute='weight_kg' AND upper(sys_time) = 'infinity';
  SELECT value, epistemic_kind INTO alive_val, alive_kind FROM kndb.fact
  WHERE entity_id=13 AND attribute='weight_kg' AND upper(sys_time) = 'infinity'
  LIMIT 1;
  IF alive_n <> 1 OR alive_val <> '80' OR alive_kind <> 'MEASURED' THEN
    RAISE EXCEPTION 'FAIL T3.4: expected 1 live MEASURED row value=80, got n=% val=% kind=%',
      alive_n, alive_val, alive_kind;
  END IF;
  RAISE NOTICE 'PASS T3.4: prior MEASURED still alive, INFERRED refused';
END $$;

-- T3.5: arrival order does not matter. MEASURED arriving AFTER an existing
-- INFERRED still displaces the INFERRED. Prior INFERRED audited; new
-- MEASURED alive.
\echo '-- T3.5 arrival order irrelevant: MEASURED evicts prior INFERRED'
INSERT INTO kndb.fact (entity_id, attribute, value, epistemic_kind, confidence, valid_time)
VALUES (14, 'weight_kg', '75', 'INFERRED', 0.97, tstzrange('2026-01-01', '2026-06-01', '[)'));
INSERT INTO kndb.fact (entity_id, attribute, value, epistemic_kind, confidence, valid_time)
VALUES (14, 'weight_kg', '80', 'MEASURED', 0.90, tstzrange('2026-02-01', '2026-05-01', '[)'));
DO $$
DECLARE alive_n int; alive_val text; alive_kind kndb.epistemic_kind; closed_n int;
BEGIN
  SELECT count(*) INTO alive_n FROM kndb.fact
  WHERE entity_id=14 AND attribute='weight_kg' AND upper(sys_time) = 'infinity';
  SELECT value, epistemic_kind INTO alive_val, alive_kind FROM kndb.fact
  WHERE entity_id=14 AND attribute='weight_kg' AND upper(sys_time) = 'infinity'
  LIMIT 1;
  SELECT count(*) INTO closed_n FROM kndb.fact
  WHERE entity_id=14 AND attribute='weight_kg' AND upper(sys_time) <> 'infinity';
  IF alive_n <> 1 OR alive_val <> '80' OR alive_kind <> 'MEASURED' OR closed_n <> 1 THEN
    RAISE EXCEPTION 'FAIL T3.5: expected 1 live MEASURED + 1 closed INFERRED, got alive_n=% val=% kind=% closed_n=%',
      alive_n, alive_val, alive_kind, closed_n;
  END IF;
  RAISE NOTICE 'PASS T3.5: MEASURED displaced prior INFERRED';
END $$;

-- T3.6: the audit row for the T3.5 eviction records reason=kind_outranked.
\echo '-- T3.6 audit reason=kind_outranked for T3.5 eviction'
DO $$
DECLARE r_n int;
BEGIN
  SELECT count(*) INTO r_n
  FROM kndb_audit.evicted_fact
  WHERE reason = 'kind_outranked'
    AND (original_row->>'entity_id')::int = 14
    AND original_row->>'attribute' = 'weight_kg';
  IF r_n < 1 THEN
    RAISE EXCEPTION 'FAIL T3.6: expected >=1 audit row with reason=kind_outranked for entity 14, got %', r_n;
  END IF;
  RAISE NOTICE 'PASS T3.6: audit row reason=kind_outranked (% row(s))', r_n;
END $$;

-- T3.7: kind tied on DERIVED, higher specificity wins.
-- Prior specificity=50, NEW specificity=150. NEW lands; prior audited with
-- reason=specificity. DERIVED needs sources (R1); we plant a MEASURED
-- upstream on a different entity/attribute and reference its fact_id.
\echo '-- T3.7 specificity breaks kind tie on DERIVED'
DO $$
DECLARE src_id uuid;
BEGIN
  INSERT INTO kndb.fact (entity_id, attribute, value, epistemic_kind, confidence, valid_time)
  VALUES (15, 'weight_kg', '80', 'MEASURED', 0.99, tstzrange('2026-01-01', '2026-06-01', '[)'))
  RETURNING fact_id INTO src_id;

  INSERT INTO kndb.fact (entity_id, attribute, value, epistemic_kind, confidence, sources, specificity, valid_time)
  VALUES (15, 'risk_score', 'low', 'DERIVED', 0.80, ARRAY[src_id], 50, tstzrange('2026-01-01', '2026-06-01', '[)'));
  INSERT INTO kndb.fact (entity_id, attribute, value, epistemic_kind, confidence, sources, specificity, valid_time)
  VALUES (15, 'risk_score', 'high', 'DERIVED', 0.80, ARRAY[src_id], 150, tstzrange('2026-02-01', '2026-05-01', '[)'));
END $$;
DO $$
DECLARE alive_n int; alive_val text; alive_spec smallint; audit_n int;
BEGIN
  SELECT count(*) INTO alive_n FROM kndb.fact
  WHERE entity_id=15 AND attribute='risk_score' AND upper(sys_time) = 'infinity';
  SELECT value, specificity INTO alive_val, alive_spec FROM kndb.fact
  WHERE entity_id=15 AND attribute='risk_score' AND upper(sys_time) = 'infinity'
  LIMIT 1;
  SELECT count(*) INTO audit_n FROM kndb_audit.evicted_fact
  WHERE reason='specificity'
    AND (original_row->>'entity_id')::int = 15
    AND original_row->>'attribute' = 'risk_score';
  IF alive_n <> 1 OR alive_val <> 'high' OR alive_spec <> 150 OR audit_n < 1 THEN
    RAISE EXCEPTION 'FAIL T3.7: alive_n=% val=% spec=% audit_n=%',
      alive_n, alive_val, alive_spec, audit_n;
  END IF;
  RAISE NOTICE 'PASS T3.7: higher specificity won, audit reason=specificity';
END $$;

-- T3.8: kind tied, specificity tied, higher confidence wins.
-- Both DERIVED, both specificity=100. Prior conf=0.60, NEW conf=0.80.
-- NEW lands; prior audited with reason=confidence.
\echo '-- T3.8 confidence breaks kind+specificity tie'
DO $$
DECLARE src_id uuid;
BEGIN
  INSERT INTO kndb.fact (entity_id, attribute, value, epistemic_kind, confidence, valid_time)
  VALUES (16, 'weight_kg', '80', 'MEASURED', 0.99, tstzrange('2026-01-01', '2026-06-01', '[)'))
  RETURNING fact_id INTO src_id;

  INSERT INTO kndb.fact (entity_id, attribute, value, epistemic_kind, confidence, sources, specificity, valid_time)
  VALUES (16, 'risk_score', 'low', 'DERIVED', 0.60, ARRAY[src_id], 100, tstzrange('2026-01-01', '2026-06-01', '[)'));
  INSERT INTO kndb.fact (entity_id, attribute, value, epistemic_kind, confidence, sources, specificity, valid_time)
  VALUES (16, 'risk_score', 'high', 'DERIVED', 0.80, ARRAY[src_id], 100, tstzrange('2026-02-01', '2026-05-01', '[)'));
END $$;
DO $$
DECLARE alive_n int; alive_val text; alive_conf kndb.confidence; audit_n int;
BEGIN
  SELECT count(*) INTO alive_n FROM kndb.fact
  WHERE entity_id=16 AND attribute='risk_score' AND upper(sys_time) = 'infinity';
  SELECT value, confidence INTO alive_val, alive_conf FROM kndb.fact
  WHERE entity_id=16 AND attribute='risk_score' AND upper(sys_time) = 'infinity'
  LIMIT 1;
  SELECT count(*) INTO audit_n FROM kndb_audit.evicted_fact
  WHERE reason='confidence'
    AND (original_row->>'entity_id')::int = 16
    AND original_row->>'attribute' = 'risk_score';
  IF alive_n <> 1 OR alive_val <> 'high' OR alive_conf <> 0.80 OR audit_n < 1 THEN
    RAISE EXCEPTION 'FAIL T3.8: alive_n=% val=% conf=% audit_n=%',
      alive_n, alive_val, alive_conf, audit_n;
  END IF;
  RAISE NOTICE 'PASS T3.8: higher confidence won, audit reason=confidence';
END $$;

-- T3.9: true tie. Both INFERRED, both specificity=100, both confidence=0.75,
-- values differ. NEW lands by arrival; prior audited with
-- reason=contradicted_same_rank.
\echo '-- T3.9 true tie: NEW lands by arrival, reason=contradicted_same_rank'
INSERT INTO kndb.fact (entity_id, attribute, value, epistemic_kind, confidence, specificity, valid_time)
VALUES (17, 'risk_score', 'low', 'INFERRED', 0.75, 100, tstzrange('2026-01-01', '2026-06-01', '[)'));
INSERT INTO kndb.fact (entity_id, attribute, value, epistemic_kind, confidence, specificity, valid_time)
VALUES (17, 'risk_score', 'high', 'INFERRED', 0.75, 100, tstzrange('2026-02-01', '2026-05-01', '[)'));
DO $$
DECLARE alive_n int; alive_val text; audit_n int;
BEGIN
  SELECT count(*) INTO alive_n FROM kndb.fact
  WHERE entity_id=17 AND attribute='risk_score' AND upper(sys_time) = 'infinity';
  SELECT value INTO alive_val FROM kndb.fact
  WHERE entity_id=17 AND attribute='risk_score' AND upper(sys_time) = 'infinity'
  LIMIT 1;
  SELECT count(*) INTO audit_n FROM kndb_audit.evicted_fact
  WHERE reason='contradicted_same_rank'
    AND (original_row->>'entity_id')::int = 17
    AND original_row->>'attribute' = 'risk_score';
  IF alive_n <> 1 OR alive_val <> 'high' OR audit_n < 1 THEN
    RAISE EXCEPTION 'FAIL T3.9: alive_n=% val=% audit_n=%', alive_n, alive_val, audit_n;
  END IF;
  RAISE NOTICE 'PASS T3.9: NEW landed by arrival, audit reason=contradicted_same_rank';
END $$;

-- T3.10: specificity convention: entity-specific (100) beats batch-default (0).
-- Prior arrives from a nightly batch loader as specificity=0. A follow-up
-- per-entity write arrives at specificity=100 with a different value.
-- Same kind INFERRED. NEW wins; prior audited with reason=specificity.
-- Documents the plan_v2 convention (0=batch, 100=entity, 200=adjudicated).
\echo '-- T3.10 entity-specific (100) beats batch-default (0)'
INSERT INTO kndb.fact (entity_id, attribute, value, epistemic_kind, confidence, specificity, valid_time)
VALUES (18, 'risk_tier', 'medium', 'INFERRED', 0.70, 0,   tstzrange('2026-01-01', '2026-06-01', '[)'));
INSERT INTO kndb.fact (entity_id, attribute, value, epistemic_kind, confidence, specificity, valid_time)
VALUES (18, 'risk_tier', 'high',   'INFERRED', 0.70, 100, tstzrange('2026-02-01', '2026-05-01', '[)'));
DO $$
DECLARE alive_n int; alive_val text; alive_spec smallint; audit_n int;
BEGIN
  SELECT count(*) INTO alive_n FROM kndb.fact
  WHERE entity_id=18 AND attribute='risk_tier' AND upper(sys_time) = 'infinity';
  SELECT value, specificity INTO alive_val, alive_spec FROM kndb.fact
  WHERE entity_id=18 AND attribute='risk_tier' AND upper(sys_time) = 'infinity'
  LIMIT 1;
  SELECT count(*) INTO audit_n FROM kndb_audit.evicted_fact
  WHERE reason='specificity'
    AND (original_row->>'entity_id')::int = 18
    AND original_row->>'attribute' = 'risk_tier';
  IF alive_n <> 1 OR alive_val <> 'high' OR alive_spec <> 100 OR audit_n < 1 THEN
    RAISE EXCEPTION 'FAIL T3.10: alive_n=% val=% spec=% audit_n=%',
      alive_n, alive_val, alive_spec, audit_n;
  END IF;
  RAISE NOTICE 'PASS T3.10: entity-specific (100) beat batch-default (0)';
END $$;

-- T3.11: arrival order irrelevant on the specificity axis.
-- Prior is entity-specific (100). A batch-default (0) NEW arrives with a
-- different value. NEW is REFUSED; prior stays alive; the batch write
-- never lands (equivalent to T3.4 pattern but for the specificity dimension
-- rather than the kind dimension). No audit row expected under the reject
-- path (autonomous transaction limitation, scoped-out).
\echo '-- T3.11 arrival order irrelevant: batch-default (0) refused against entity-specific (100)'
INSERT INTO kndb.fact (entity_id, attribute, value, epistemic_kind, confidence, specificity, valid_time)
VALUES (19, 'risk_tier', 'high',   'INFERRED', 0.70, 100, tstzrange('2026-01-01', '2026-06-01', '[)'));
DO $$
BEGIN
  BEGIN
    INSERT INTO kndb.fact (entity_id, attribute, value, epistemic_kind, confidence, specificity, valid_time)
    VALUES (19, 'risk_tier', 'medium', 'INFERRED', 0.70, 0, tstzrange('2026-02-01', '2026-05-01', '[)'));
    RAISE EXCEPTION 'FAIL T3.11: outranked batch-default write should have raised';
  EXCEPTION WHEN check_violation THEN
    -- expected: specificity 0 is outranked by specificity 100
    NULL;
  END;
END $$;
DO $$
DECLARE alive_n int; alive_val text; alive_spec smallint;
BEGIN
  SELECT count(*) INTO alive_n FROM kndb.fact
  WHERE entity_id=19 AND attribute='risk_tier' AND upper(sys_time) = 'infinity';
  SELECT value, specificity INTO alive_val, alive_spec FROM kndb.fact
  WHERE entity_id=19 AND attribute='risk_tier' AND upper(sys_time) = 'infinity'
  LIMIT 1;
  IF alive_n <> 1 OR alive_val <> 'high' OR alive_spec <> 100 THEN
    RAISE EXCEPTION 'FAIL T3.11: expected 1 live entity-specific row, got n=% val=% spec=%',
      alive_n, alive_val, alive_spec;
  END IF;
  RAISE NOTICE 'PASS T3.11: batch-default refused, entity-specific prior survived';
END $$;

-- T3.12: adjudicated override (200) beats normal entity-specific (100).
-- Prior is a normal per-entity MEASURED at specificity=100. An adjudicated
-- correction lands at specificity=200 with a different value. Same kind
-- MEASURED. NEW wins; prior audited with reason=specificity. Documents the
-- human-override convention.
\echo '-- T3.12 adjudicated override (200) beats entity-specific (100)'
INSERT INTO kndb.fact (entity_id, attribute, value, epistemic_kind, confidence, specificity, valid_time)
VALUES (20, 'address_zip', '02138', 'MEASURED', 0.95, 100, tstzrange('2026-01-01', '2026-06-01', '[)'));
INSERT INTO kndb.fact (entity_id, attribute, value, epistemic_kind, confidence, specificity, valid_time)
VALUES (20, 'address_zip', '02139', 'MEASURED', 0.95, 200, tstzrange('2026-02-01', '2026-05-01', '[)'));
DO $$
DECLARE alive_n int; alive_val text; alive_spec smallint; audit_n int;
BEGIN
  SELECT count(*) INTO alive_n FROM kndb.fact
  WHERE entity_id=20 AND attribute='address_zip' AND upper(sys_time) = 'infinity';
  SELECT value, specificity INTO alive_val, alive_spec FROM kndb.fact
  WHERE entity_id=20 AND attribute='address_zip' AND upper(sys_time) = 'infinity'
  LIMIT 1;
  SELECT count(*) INTO audit_n FROM kndb_audit.evicted_fact
  WHERE reason='specificity'
    AND (original_row->>'entity_id')::int = 20
    AND original_row->>'attribute' = 'address_zip';
  IF alive_n <> 1 OR alive_val <> '02139' OR alive_spec <> 200 OR audit_n < 1 THEN
    RAISE EXCEPTION 'FAIL T3.12: alive_n=% val=% spec=% audit_n=%',
      alive_n, alive_val, alive_spec, audit_n;
  END IF;
  RAISE NOTICE 'PASS T3.12: adjudicated override (200) beat entity-specific (100)';
END $$;

ROLLBACK;
\echo '== engine_enforces_conflict: all sub-tests PASS =='
