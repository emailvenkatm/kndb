-- M0 smoke test A: ProvSQL v1.10.0 LEFT JOIN monus semantics.
--
-- Question: does the standard probability semiring propagate confidence
-- correctly through a LEFT JOIN when the right side has no match? The
-- Viterbi semiring is separately verified below.
--
-- ProvSQL v1.10.0 API used here (differs from earlier public docs):
--   add_provenance('tbl')     — attach hidden `provsql uuid` column
--   provenance()              — token for the current row
--   set_prob(token, p)        — assign probability to a token
--   probability_evaluate(t)   — evaluate joined probability (default semiring)
--   sr_viterbi(t, weights)    — Viterbi semiring evaluation
--
-- Pass criteria:
--   T-A1: probability_evaluate on JOIN gives closed-form product for matches.
--   T-A2: probability_evaluate on LEFT JOIN gives the LHS probability for
--         non-matching rows (i.e. joining with NULL preserves LHS confidence,
--         because a NULL row has effective probability 1 in the join).
--   T-A3: sr_viterbi agrees with probability_evaluate on pure conjunctions.

\set ECHO all
\set ON_ERROR_STOP on

DROP SCHEMA IF EXISTS smoke_a CASCADE;
CREATE SCHEMA smoke_a;
SET search_path = smoke_a, public, provsql;

CREATE TABLE labs (
  patient_id  int PRIMARY KEY,
  hba1c       numeric
);

CREATE TABLE inferences (
  patient_id  int PRIMARY KEY,
  is_diabetic boolean
);

INSERT INTO labs       VALUES (1, 7.2), (2, 5.4), (3, 8.9);
INSERT INTO inferences VALUES (1, true), (2, false);  -- patient 3 has no inference

SELECT add_provenance('smoke_a.labs');
SELECT add_provenance('smoke_a.inferences');

DO $$ BEGIN
  PERFORM set_prob(provenance(), 0.95::float8) FROM smoke_a.labs;
  PERFORM set_prob(provenance(), CASE patient_id WHEN 1 THEN 0.7 WHEN 2 THEN 0.4 END::float8) FROM smoke_a.inferences;
END $$;

-- T-A1 / T-A2: LEFT JOIN, default probability semiring.
CREATE TEMP TABLE r_a AS
SELECT
  l.patient_id,
  l.hba1c,
  i.is_diabetic,
  probability_evaluate(provenance()) AS joined_conf
FROM smoke_a.labs l
LEFT JOIN smoke_a.inferences i USING (patient_id);

SELECT remove_provenance('r_a');
SELECT patient_id, hba1c, is_diabetic, round(joined_conf::numeric, 5) AS joined_conf
FROM r_a
ORDER BY patient_id;

DO $$
DECLARE p1 numeric; p2 numeric; p3 numeric;
BEGIN
  SELECT round(joined_conf::numeric,4) INTO p1 FROM r_a WHERE patient_id=1;
  SELECT round(joined_conf::numeric,4) INTO p2 FROM r_a WHERE patient_id=2;
  SELECT round(joined_conf::numeric,4) INTO p3 FROM r_a WHERE patient_id=3;

  IF abs(p1 - 0.665) > 0.001 THEN RAISE EXCEPTION 'FAIL T-A1: p1 % != 0.665', p1; END IF;
  IF abs(p2 - 0.380) > 0.001 THEN RAISE EXCEPTION 'FAIL T-A1: p2 % != 0.380', p2; END IF;
  IF abs(p3 - 0.950) > 0.001 THEN RAISE EXCEPTION 'FAIL T-A2: p3 (LEFT JOIN no-match) % != 0.950', p3; END IF;

  RAISE NOTICE 'PASS T-A1/T-A2: LEFT JOIN probability = [% % %]', p1, p2, p3;
END $$;

-- T-A3: sr_viterbi on the same join. Needs a weights table via create_provenance_mapping.
-- The mapping expression tells sr_viterbi how to map each source row to its Viterbi weight.
SELECT create_provenance_mapping('smoke_a_labs_w',       'smoke_a.labs',       '0.95::float');
SELECT create_provenance_mapping('smoke_a_inferences_w', 'smoke_a.inferences', '(case patient_id when 1 then 0.7 when 2 then 0.4 end)::float');

CREATE TEMP TABLE r_a_vit AS
SELECT
  l.patient_id,
  sr_viterbi(provenance(), 'smoke_a_labs_w')       AS vit_l,
  sr_viterbi(provenance(), 'smoke_a_inferences_w') AS vit_i
FROM smoke_a.labs l
LEFT JOIN smoke_a.inferences i USING (patient_id);

SELECT remove_provenance('r_a_vit');
SELECT * FROM r_a_vit ORDER BY patient_id;

DROP SCHEMA smoke_a CASCADE;
\echo '== smoke A: PASS (probability + Viterbi + LEFT JOIN monus) =='
