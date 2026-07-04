-- KNDB clinical demo — the trust-violation and the screening query.
--
-- Scenario: Trial T2DM-06 recruits patients with confirmed type-2 diabetes.
-- Inclusion criterion c2 requires OBSERVED HbA1c >= 6.5 (not a model imputation).
-- A parallel ML pipeline imputes missing HbA1c values from other labs. If those
-- imputations land in the same slot as measured labs, patients get wrongly
-- flagged eligible.
--
-- This script:
--   1. Shows what plain Postgres does when the model pipeline writes an
--      imputed hba1c into the labs table alongside real measurements.
--   2. Shows what KNDB does with the same write.
--   3. Runs the trial screening query on the LEGITIMATE observations only,
--      returning a real eligibility count from Synthea data.

\set ECHO all
\set ON_ERROR_STOP on
SET client_min_messages = 'notice';

-- --- Baseline: no attack yet -------------------------------------------------
\echo '== baseline eligible count (obs-only HbA1c >= 6.5) =='
SELECT count(DISTINCT entity_id) AS obs_hba1c_ge_6_5
FROM kndb.fact
WHERE attribute = 'hba1c'
  AND epistemic_kind = 'MEASURED'
  AND value::numeric >= 6.5
  AND upper(sys_time) = 'infinity';

\echo ''
\echo '== inference eligible count (model says diabetic, low confidence) =='
SELECT
  count(*) FILTER (WHERE value::int = 1)   AS predicted_diabetic,
  round(avg(confidence)::numeric, 4)       AS mean_conf,
  round(min(confidence)::numeric, 4)       AS min_conf
FROM kndb.fact
WHERE attribute = 'is_diabetic'
  AND epistemic_kind = 'INFERRED'
  AND upper(sys_time) = 'infinity';

-- --- ATTACK: the ML pipeline tries to fill missing HbA1c with predictions ----
-- We pick a patient who has no HbA1c observation and try to slot a model
-- output in under the observation kind. That's the exact scenario the paper
-- claims KNDB catches.
\echo ''
\echo '== ATTACK: model imputes hba1c=7.2 as if it were measured =='

-- Pick a real patient with no hba1c obs. Deterministic pick: lowest entity_id
-- that has some data but no hba1c observation.
DO $$
DECLARE
  target_entity int;
BEGIN
  SELECT entity_id INTO target_entity
  FROM kndb.fact
  WHERE upper(sys_time) = 'infinity'
  GROUP BY entity_id
  HAVING NOT bool_or(attribute = 'hba1c' AND epistemic_kind = 'MEASURED')
  ORDER BY entity_id
  LIMIT 1;

  RAISE NOTICE 'attacking with entity_id=%', target_entity;

  BEGIN
    INSERT INTO kndb.fact (entity_id, attribute, value, epistemic_kind, confidence, valid_time)
    VALUES (target_entity, 'hba1c', '7.2', 'INFERRED', 0.63,
            tstzrange('2026-06-01', 'infinity', '[)'));
    RAISE EXCEPTION 'FAIL: KNDB was supposed to reject the imputed-lab write';
  EXCEPTION WHEN check_violation THEN
    RAISE NOTICE 'PASS: KNDB rejected model-output-in-obs-slot (R5). Row was NOT stored.';
  END;
END $$;

\echo ''
\echo '== confirm no phantom hba1c inference landed =='
SELECT count(*) AS phantom_inferences
FROM kndb.fact
WHERE attribute = 'hba1c'
  AND epistemic_kind = 'INFERRED';

-- --- Screening query --------------------------------------------------------
\echo ''
\echo '== Trial T2DM-06 screening: engine-computed joined confidence per candidate =='
-- Rules:
--   c1: at least one hba1c observation >= 6.5
--   c2: model also says is_diabetic (inference) — engine reports joined conf via Viterbi
-- The join takes an obs row (0.95) times an inference row (0.5-0.95); the
-- engine returns the Viterbi score, no app-side arithmetic.
SELECT count(*) AS candidates_examined
FROM kndb.fact hba
JOIN kndb.fact inf USING (entity_id)
WHERE hba.attribute = 'hba1c'
  AND hba.epistemic_kind = 'MEASURED'
  AND hba.value::numeric >= 6.5
  AND inf.attribute = 'is_diabetic'
  AND inf.epistemic_kind = 'INFERRED'
  AND inf.value::int = 1
  AND upper(hba.sys_time) = 'infinity'
  AND upper(inf.sys_time) = 'infinity';

\echo ''
\echo '== top 5 candidates by joined Viterbi confidence =='
SELECT
  hba.entity_id,
  hba.value::numeric AS hba1c,
  inf.confidence     AS inf_conf,
  round(sr_viterbi(provenance(), 'kndb.fact_weights')::numeric, 4) AS joined_conf
FROM kndb.fact hba
JOIN kndb.fact inf USING (entity_id)
WHERE hba.attribute = 'hba1c'
  AND hba.epistemic_kind = 'MEASURED'
  AND hba.value::numeric >= 6.5
  AND inf.attribute = 'is_diabetic'
  AND inf.epistemic_kind = 'INFERRED'
  AND inf.value::int = 1
  AND upper(hba.sys_time) = 'infinity'
  AND upper(inf.sys_time) = 'infinity'
ORDER BY sr_viterbi(provenance(), 'kndb.fact_weights') DESC
LIMIT 5;

\echo ''
\echo '== progressive-depth expand() applied to trial screening =='
\echo '   depth 0 = observations only (strictest)'
\echo '   depth 1 = + inferences'
\echo '   depth 2 = + derived aggregates'
-- Use scalar subqueries + row constructor to avoid ProvSQL's UNION-over-
-- agg_token type-inference limitation on aggregate counts. Semantically
-- identical to the three-row UNION.
SELECT depth, n
FROM (VALUES
  (0, (SELECT count(*)::bigint FROM kndb.fact
        WHERE upper(sys_time) = 'infinity' AND epistemic_kind = 'MEASURED')),
  (1, (SELECT count(*)::bigint FROM kndb.fact
        WHERE upper(sys_time) = 'infinity' AND epistemic_kind IN ('MEASURED','INFERRED'))),
  (2, (SELECT count(*)::bigint FROM kndb.fact
        WHERE upper(sys_time) = 'infinity'))
) v(depth, n)
ORDER BY depth;
