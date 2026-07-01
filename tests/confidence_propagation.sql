-- Tests for Primitive 2 — Viterbi confidence propagation.
-- Requires engine/*.sql applied (ProvSQL added to kndb.fact).

SET client_min_messages = 'notice';
BEGIN;
TRUNCATE kndb.fact, kndb_audit.evicted_fact, kndb.slot_kind, kndb.conflict_policy CASCADE;

-- Insert one obs (0.95), one inference (0.7 for patient 1, 0.4 for patient 2).
INSERT INTO kndb.fact (entity_id, attribute, value, epistemic_kind, confidence, valid_time) VALUES
  (1, 'hba1c',       '7.2',  'observation', 0.95, tstzrange('2026-01-01', 'infinity', '[)')),
  (2, 'hba1c',       '5.4',  'observation', 0.95, tstzrange('2026-01-01', 'infinity', '[)')),
  (1, 'is_diabetic', 'true', 'inference',   0.70, tstzrange('2026-01-01', 'infinity', '[)')),
  (2, 'is_diabetic', 'false','inference',   0.40, tstzrange('2026-01-01', 'infinity', '[)'));

-- Closed-form: joined confidence via Viterbi is per-row product.
-- p1: 0.95 * 0.70 = 0.665
-- p2: 0.95 * 0.40 = 0.380

-- Build the Viterbi weights table from the freshly-populated fact rows.
SELECT kndb.refresh_weights();

\echo '-- T2.1 joined confidence via ProvSQL sr_viterbi matches closed-form'
DO $$
DECLARE
  p1_conf numeric; p2_conf numeric;
BEGIN
  -- Join lab-obs with matching inference by entity, get engine-computed
  -- Viterbi confidence of the join. Each patient produces exactly one row.
  SELECT round(provsql.sr_viterbi(provenance(), 'kndb.fact_weights')::numeric, 4)
    INTO p1_conf
  FROM kndb.fact l
  JOIN kndb.fact i USING (entity_id)
  WHERE l.entity_id = 1
    AND l.attribute = 'hba1c'
    AND i.attribute = 'is_diabetic';

  SELECT round(provsql.sr_viterbi(provenance(), 'kndb.fact_weights')::numeric, 4)
    INTO p2_conf
  FROM kndb.fact l
  JOIN kndb.fact i USING (entity_id)
  WHERE l.entity_id = 2
    AND l.attribute = 'hba1c'
    AND i.attribute = 'is_diabetic';

  IF abs(p1_conf - 0.665) > 0.001 THEN
    RAISE EXCEPTION 'FAIL T2.1: p1 joined Viterbi % != 0.665', p1_conf;
  END IF;
  IF abs(p2_conf - 0.380) > 0.001 THEN
    RAISE EXCEPTION 'FAIL T2.1: p2 joined Viterbi % != 0.380', p2_conf;
  END IF;
  RAISE NOTICE 'PASS T2.1: p1 = %, p2 = % (closed-form Viterbi)', p1_conf, p2_conf;
END $$;

ROLLBACK;
\echo '== confidence_propagation: all sub-tests PASS =='
