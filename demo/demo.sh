#!/usr/bin/env bash
# KNDB 60-second demo. Uses the running kndb-postgres container.
# Run: ./demo/demo.sh   or   make demo
set -euo pipefail

PSQL() { docker compose exec -T kndb-postgres psql -U kndb -d kndb -X -q "$@"; }
PSQL_NAMED() { docker compose exec -T kndb-postgres psql -U kndb -d kndb -X "$@"; }

section() { printf '\n\033[1;36m== %s ==\033[0m\n' "$1"; }
subsec()  { printf '\033[1;33m-- %s --\033[0m\n'   "$1"; }
say()     { printf '  %s\n' "$1"; }

# -------------------------------------------------------------------------
section "SETUP — a naive Postgres schema and the KNDB schema, side by side"
# -------------------------------------------------------------------------
PSQL <<'SQL' >/dev/null
DROP SCHEMA IF EXISTS demo_plain CASCADE;
CREATE SCHEMA demo_plain;

CREATE TABLE demo_plain.labs (
  patient_id int,
  attribute  text,
  value      text,
  effective  timestamptz DEFAULT now()
);

-- kndb.fact + engine already exists (from make engine). Reset just its data.
TRUNCATE kndb.fact, kndb_audit.evicted_fact, kndb.slot_kind, kndb.conflict_policy CASCADE;

-- KNDB step the naive schema cannot express: register hba1c as MEASURED-typed.
INSERT INTO kndb.slot_kind (attribute, required_kind) VALUES
  ('hba1c',        'MEASURED'),
  ('bp_systolic',  'MEASURED'),
  ('is_diabetic',  'INFERRED');
SQL
say "created demo_plain.labs (unconstrained), left kndb.fact typed."

# -------------------------------------------------------------------------
section "SCENE 1 — a model writes its guess into the labs column"
# -------------------------------------------------------------------------
say "Story: a service pipeline uses a model to fill missing HbA1c values."
say "Nothing tells the DB that hba1c must be a real measurement."
sleep 1

subsec "1a: naive Postgres accepts the model guess silently"
PSQL_NAMED <<'SQL'
INSERT INTO demo_plain.labs (patient_id, attribute, value) VALUES
  (42, 'hba1c', '7.8');   -- looks like a lab result. It isn't.
SELECT patient_id, attribute, value FROM demo_plain.labs;
SQL
say "→ Postgres stored '7.8' as if the patient had been measured. Silently."
sleep 1

subsec "1b: KNDB rejects the same write at write time"
set +e
PSQL_NAMED <<'SQL' 2>&1 | head -8
INSERT INTO kndb.fact (entity_id, attribute, value, epistemic_kind, confidence, valid_time)
VALUES (42, 'hba1c', '7.8', 'INFERRED', 0.7, tstzrange('2026-06-01', 'infinity', '[)'));
SQL
set -e
say "→ ERROR 23514, rule R5: attribute hba1c is registered as MEASURED, got INFERRED."
say "  Write refused BEFORE the row lands. Engine, not app code."
sleep 1

# -------------------------------------------------------------------------
section "SCENE 2 — the SAME model output, properly labeled, is accepted"
# -------------------------------------------------------------------------
PSQL_NAMED <<'SQL'
-- Ground MEASURED fact first.
INSERT INTO kndb.fact (entity_id, attribute, value, epistemic_kind, confidence, valid_time)
VALUES (42, 'hba1c', '7.2', 'MEASURED', 0.95, tstzrange('2026-06-01', 'infinity', '[)'));

-- INFERRED fact labeled honestly — accepted with its confidence.
INSERT INTO kndb.fact (entity_id, attribute, value, epistemic_kind, confidence, valid_time)
VALUES (42, 'is_diabetic', 'true', 'INFERRED', 0.70, tstzrange('2026-06-01', 'infinity', '[)'));

SELECT epistemic_kind, attribute, value, confidence FROM kndb.fact WHERE entity_id=42 ORDER BY epistemic_kind;
SQL
say "→ Same numbers, but the epistemic distinction is captured. Downstream can act on it."
sleep 1

# -------------------------------------------------------------------------
section "SCENE 3 — joined confidence via Viterbi, computed by the engine"
# -------------------------------------------------------------------------
say "Question: how confident is 'this patient is diabetic based on their HbA1c'?"
say "Closed-form Viterbi: 0.95 (lab) × 0.70 (inference) = 0.665."
PSQL_NAMED <<'SQL'
SELECT kndb.refresh_weights();

SELECT
  l.entity_id AS patient,
  l.value     AS hba1c,
  i.value     AS is_diabetic,
  round(provsql.sr_viterbi(provenance(), 'kndb.fact_weights')::numeric, 4) AS joined_conf
FROM kndb.fact l
JOIN kndb.fact i USING (entity_id)
WHERE l.attribute='hba1c' AND i.attribute='is_diabetic';
SQL
say "→ engine returned 0.6650. No app-side arithmetic. Viterbi semiring."
say "→ naive Postgres has no honest answer to this question — 'confidence' would"
say "  have to be reconstructed in every application layer, differently each time."

# -------------------------------------------------------------------------
section "END — three engine-enforced guarantees, one connection, zero app code"
# -------------------------------------------------------------------------
say "1. epistemic type checked at write time (Scene 1)."
say "2. labels preserved end-to-end (Scene 2)."
say "3. confidence propagated correctly through joins (Scene 3)."
echo
