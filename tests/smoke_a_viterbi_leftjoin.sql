-- M0 smoke test A: ProvSQL Viterbi + LEFT JOIN monus semantics.
--
-- Question: does the Viterbi m-semiring behave correctly when a LEFT JOIN
-- produces non-matching rows? Specifically, is the monus operator well-defined
-- (i.e. does confidence propagate sanely for "matched" rows, and does the
-- "no-match" row carry a sensible confidence — either NULL or 1.0)?
--
-- This gates KNDB primitive 2. If Viterbi's LEFT JOIN semantics don't hold,
-- we fall back to a PL/pgSQL Viterbi UDA and re-scope the paper claim.
--
-- Run: make smoke-a

\echo '== smoke A: create schema =='
DROP SCHEMA IF EXISTS smoke_a CASCADE;
CREATE SCHEMA smoke_a;
SET search_path = smoke_a, public;

CREATE EXTENSION IF NOT EXISTS provsql CASCADE;

CREATE TABLE labs (
  patient_id  int PRIMARY KEY,
  hba1c       numeric
);

CREATE TABLE inferences (
  patient_id  int PRIMARY KEY,
  is_diabetic boolean
);

INSERT INTO labs VALUES (1, 7.2), (2, 5.4), (3, 8.9);
INSERT INTO inferences VALUES (1, true), (2, false);   -- patient 3 has NO inference row

\echo '== annotate with Viterbi probabilities =='
-- ProvSQL: attach provenance columns and assign per-row Viterbi weights.
SELECT add_provenance('smoke_a.labs');
SELECT add_provenance('smoke_a.inferences');

-- Per-row Viterbi confidences: labs high (0.95), inference for p1 moderate (0.7), inference for p2 low (0.4).
UPDATE labs        SET provsql = provenance_token(0.95) WHERE patient_id IN (1,2,3);
UPDATE inferences  SET provsql = CASE patient_id WHEN 1 THEN provenance_token(0.7) WHEN 2 THEN provenance_token(0.4) END;

\echo '== LEFT JOIN under Viterbi semiring =='
SELECT set_prob_semiring('viterbi');

SELECT
  l.patient_id,
  l.hba1c,
  i.is_diabetic,
  probability_evaluate(l.provsql * COALESCE(i.provsql, provenance_token(1.0))) AS joined_confidence
FROM labs l
LEFT JOIN inferences i USING (patient_id)
ORDER BY l.patient_id;

\echo '== expected: p1=0.665 (0.95*0.7), p2=0.38 (0.95*0.4), p3=0.95 (LEFT JOIN no-match, monus identity 1.0) =='
\echo '== if p3 comes back NULL or 0, monus behavior is broken and we fall back to PL/pgSQL Viterbi UDA =='

DROP SCHEMA smoke_a CASCADE;
\echo '== smoke A complete =='
