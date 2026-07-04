-- KNDB clinical demo — load real Synthea data into typed kndb.fact and set
-- up the trial screening context. Assumes:
--   * data/load_postgres.sh has populated stage.observations / stage.inferences
--     / stage.derived from real Synthea CSVs.
--   * engine/*.sql has been applied (kndb.fact, triggers, ProvSQL wired).
--
-- Output: kndb.fact holds real observations (labs), model inferences
-- (is_diabetic predictions with per-row confidence), and derived aggregates
-- (90-day BP + HbA1c averages). Slot kinds registered so the paper's
-- attack scenario has a real target.

\set ECHO all
\set ON_ERROR_STOP on
SET client_min_messages = 'notice';

BEGIN;

TRUNCATE kndb.fact, kndb_audit.evicted_fact, kndb.slot_kind, kndb.conflict_policy CASCADE;

-- Bulk load: disable the resolve_conflict trigger so identical-value repeat
-- observations (Synthea has some — same lab value across encounters) don't
-- get absorbed, which would delete stage_ids from _obs_id_map and empty out
-- derived rows' `sources` arrays. Live user writes still see conflict
-- resolution (re-enabled at commit). The epistemic-kind trigger stays on
-- so kind rules are still enforced during load.
ALTER TABLE kndb.fact DISABLE TRIGGER trg_resolve_conflict;

-- Bridge stage.patient_id (Synthea text UUID) to an int entity_id — kndb.fact
-- uses int entity_id and we don't want to widen the schema for the demo. A
-- deterministic hash suffices; collisions across 10k patients are negligible.
CREATE OR REPLACE FUNCTION kndb.patient_int(p text) RETURNS int
  LANGUAGE sql IMMUTABLE AS
$$ SELECT ('x' || substr(md5(p), 1, 8))::bit(32)::int $$;

-- --- register slot kinds -----------------------------------------------------
-- hba1c and bp_systolic are LAB observations. A model output that lands here
-- is the attack we demonstrate.
INSERT INTO kndb.slot_kind (attribute, required_kind) VALUES
  ('hba1c',        'MEASURED'),
  ('systolic_bp',  'MEASURED'),
  ('diastolic_bp', 'MEASURED'),
  ('ldl',          'MEASURED'),
  ('fasting_glucose', 'MEASURED'),
  ('is_diabetic',  'INFERRED'),
  ('avg_systolic_bp_90d', 'DERIVED'),
  ('avg_hba1c_90d',       'DERIVED');

-- --- observations: real Synthea labs -----------------------------------------
INSERT INTO kndb.fact (entity_id, attribute, value, epistemic_kind, confidence, valid_time)
SELECT
  kndb.patient_int(patient_id),
  code,
  value::text,
  'MEASURED'::kndb.epistemic_kind,
  confidence::numeric(6,5),
  tstzrange(effective_time::timestamptz, 'infinity', '[)')
FROM stage.observations
WHERE code IN ('hba1c','systolic_bp','diastolic_bp','ldl','fasting_glucose');

-- --- inferences: synthesized model predictions -------------------------------
-- source_lab_ids in stage refers to stage.observations.id. To wire kndb.sources
-- correctly we need to map those ints to the newly-inserted kndb.fact UUIDs.
-- We keep a mapping table for this handoff — one-shot, not a general primitive.
CREATE TEMP TABLE _obs_id_map AS
SELECT o.id AS stage_id, f.fact_id AS kndb_id
FROM stage.observations o
JOIN kndb.fact f
  ON f.entity_id = kndb.patient_int(o.patient_id)
 AND f.attribute = o.code
 AND lower(f.valid_time) = o.effective_time::timestamptz;

INSERT INTO kndb.fact (entity_id, attribute, value, epistemic_kind, confidence, sources, valid_time)
SELECT
  kndb.patient_int(i.patient_id),
  i.attribute,
  i.value::text,
  'INFERRED'::kndb.epistemic_kind,
  LEAST(0.99, i.confidence)::numeric(6,5),   -- R4 forbids confidence >= 1.0
  ARRAY(
    SELECT m.kndb_id FROM _obs_id_map m WHERE m.stage_id = ANY(i.source_lab_ids)
  ),
  tstzrange(now(), 'infinity', '[)')
FROM stage.inferences i;

-- --- derived aggregates ------------------------------------------------------
-- Skip derived rows whose ALL sources were dropped (e.g., all-absorbed
-- duplicates) — they'd hit R1 (empty sources). Rare in practice with the
-- conflict trigger disabled above, but a defensive filter regardless.
INSERT INTO kndb.fact (entity_id, attribute, value, epistemic_kind, confidence, sources, valid_time)
SELECT
  kndb.patient_int(d.patient_id),
  d.attribute,
  d.value::text,
  'DERIVED'::kndb.epistemic_kind,
  0.90::numeric(6,5),                        -- derived aggregates: conf < 1
  ARRAY(
    SELECT m.kndb_id FROM _obs_id_map m WHERE m.stage_id = ANY(d.sources)
  ),
  tstzrange(now(), 'infinity', '[)')
FROM stage.derived d
WHERE EXISTS (
  SELECT 1 FROM _obs_id_map m WHERE m.stage_id = ANY(d.sources)
);

-- --- fact counts by kind -----------------------------------------------------
\echo ''
\echo '== kndb.fact row counts by epistemic kind =='
SELECT epistemic_kind, count(*) AS rows
FROM kndb.fact
GROUP BY epistemic_kind
ORDER BY epistemic_kind;

\echo ''
\echo '== distinct patients =='
SELECT count(DISTINCT entity_id) AS patients FROM kndb.fact;

-- Re-enable conflict resolution for live user writes.
ALTER TABLE kndb.fact ENABLE TRIGGER trg_resolve_conflict;

COMMIT;

-- Rebuild the ProvSQL Viterbi weights table from the loaded facts.
SELECT kndb.refresh_weights();
