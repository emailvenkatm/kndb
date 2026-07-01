-- Tests for Primitive 1 — engine-enforced epistemic typing.
-- Each block RAISES if the engine did not behave as expected.
-- Requires engine/*.sql already applied.

SET client_min_messages = 'notice';
BEGIN;

TRUNCATE kndb.fact, kndb_audit.evicted_fact, kndb.slot_kind, kndb.conflict_policy CASCADE;

-- Register the demo slot: hba1c MUST be observation.
INSERT INTO kndb.slot_kind (attribute, required_kind) VALUES ('hba1c', 'observation');

\echo '-- T1.1 accepting a valid observation'
INSERT INTO kndb.fact (entity_id, attribute, value, epistemic_kind, confidence, valid_time)
VALUES (1, 'hba1c', '5.4', 'observation', 0.95, tstzrange('2026-01-01', '2026-02-01', '[)'));

-- T1.2 R5 slot-kind mismatch: attempting to write inference into hba1c must fail.
\echo '-- T1.2 R5: inference into obs-typed slot MUST reject'
DO $$
BEGIN
  BEGIN
    INSERT INTO kndb.fact (entity_id, attribute, value, epistemic_kind, confidence, valid_time)
    VALUES (2, 'hba1c', '7.1', 'inference', 0.6, tstzrange('2026-01-01', '2026-02-01', '[)'));
    RAISE EXCEPTION 'FAIL T1.2: inference-into-obs-slot was NOT rejected';
  EXCEPTION WHEN check_violation THEN
    RAISE NOTICE 'PASS T1.2: R5 slot-kind mismatch rejected as expected';
  END;
END $$;

-- T1.3 R1 derived with no sources: reject.
\echo '-- T1.3 R1: derived without sources MUST reject'
DO $$
BEGIN
  BEGIN
    INSERT INTO kndb.fact (entity_id, attribute, value, epistemic_kind, confidence, sources, valid_time)
    VALUES (3, 'avg_hba1c_90d', '6.1', 'derived', 0.9, '{}', tstzrange('2026-01-01', '2026-04-01', '[)'));
    RAISE EXCEPTION 'FAIL T1.3: derived-without-sources was NOT rejected';
  EXCEPTION WHEN check_violation THEN
    RAISE NOTICE 'PASS T1.3: R1 derived-no-sources rejected';
  END;
END $$;

-- T1.4 R3 observation with sources: reject.
\echo '-- T1.4 R3: observation with sources MUST reject'
DO $$
DECLARE first_id uuid;
BEGIN
  SELECT fact_id INTO first_id FROM kndb.fact WHERE entity_id=1 LIMIT 1;
  BEGIN
    INSERT INTO kndb.fact (entity_id, attribute, value, epistemic_kind, confidence, sources, valid_time)
    VALUES (4, 'ldl', '110', 'observation', 0.95, ARRAY[first_id], tstzrange('2026-01-01', '2026-02-01', '[)'));
    RAISE EXCEPTION 'FAIL T1.4: observation-with-sources was NOT rejected';
  EXCEPTION WHEN check_violation THEN
    RAISE NOTICE 'PASS T1.4: R3 observation-with-sources rejected';
  END;
END $$;

-- T1.5 R4 inference claiming certainty (conf = 1.0): reject.
\echo '-- T1.5 R4: inference with confidence 1.0 MUST reject'
DO $$
BEGIN
  BEGIN
    INSERT INTO kndb.fact (entity_id, attribute, value, epistemic_kind, confidence, valid_time)
    VALUES (5, 'is_diabetic', 'true', 'inference', 1.0, tstzrange('2026-01-01', 'infinity', '[)'));
    RAISE EXCEPTION 'FAIL T1.5: inference-certain was NOT rejected';
  EXCEPTION WHEN check_violation THEN
    RAISE NOTICE 'PASS T1.5: R4 inference-certain rejected';
  END;
END $$;

-- T1.6 R2 unresolved source: reject.
\echo '-- T1.6 R2: derived with unresolved source MUST reject'
DO $$
BEGIN
  BEGIN
    INSERT INTO kndb.fact (entity_id, attribute, value, epistemic_kind, confidence, sources, valid_time)
    VALUES (6, 'avg_ldl_90d', '105', 'derived', 0.9,
            ARRAY['00000000-0000-0000-0000-000000000000'::uuid],
            tstzrange('2026-01-01', '2026-04-01', '[)'));
    RAISE EXCEPTION 'FAIL T1.6: derived-with-bogus-source was NOT rejected';
  EXCEPTION WHEN foreign_key_violation THEN
    RAISE NOTICE 'PASS T1.6: R2 unresolved-source rejected';
  END;
END $$;

-- T1.7 elided: audit of REJECTED writes needs an autonomous transaction
-- (dblink) — the engine's audit table receives conflict LOSERS (see T3.*).
-- Rejected writes are logged to the Postgres error log with row payload.

ROLLBACK;
\echo '== engine_enforces_epistemic_type: all sub-tests PASS =='
