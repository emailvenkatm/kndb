#!/usr/bin/env bash
# KNDB end-to-end self-validation.
#
# Nine steps that prove the running stack does what the paper says it does.
# PASS/FAIL per step, exits non-zero on any failure. Target runtime under 30 s
# when the container is warm. Wired into CI as the final gate.
#
# Prerequisites: `make up` has brought the container up. `make engine` has
# applied engine/*.sql. This script does not restart or drop schemas; it
# runs inside a single SQL transaction so its footprint is zero.

set -uo pipefail
IFS=$'\n\t'

# Two modes:
#   local (default): psql runs inside the docker compose service kndb-postgres.
#   CI (KNDB_PSQL_DIRECT=1): psql runs on the host against a TCP DB
#                            reachable at KNDB_PSQL_HOST:KNDB_PSQL_PORT
#                            as user KNDB_PSQL_USER on db KNDB_PSQL_DB.
if [[ "${KNDB_PSQL_DIRECT:-0}" == "1" ]]; then
  PSQL() {
    psql \
      -h "${KNDB_PSQL_HOST:-127.0.0.1}" \
      -p "${KNDB_PSQL_PORT:-5433}" \
      -U "${KNDB_PSQL_USER:-kndb}" \
      -d "${KNDB_PSQL_DB:-kndb}" \
      -X -q -v ON_ERROR_STOP=1 "$@"
  }
else
  PSQL() {
    docker compose exec -T kndb-postgres \
      psql -U kndb -d kndb -X -q -v ON_ERROR_STOP=1 "$@"
  }
fi

pass_count=0
fail_count=0

pass() { printf '\033[1;32m[PASS]\033[0m %s\n' "$1"; pass_count=$((pass_count + 1)); }
fail() { printf '\033[1;31m[FAIL]\033[0m %s\n' "$1"; fail_count=$((fail_count + 1)); }
step() { printf '\n\033[1;36m[STEP %s]\033[0m %s\n' "$1" "$2"; }

start_ts=$(date +%s)

# We run every step inside `BEGIN ... ROLLBACK` so nothing lands on disk.
# Each step is a self-contained `psql` call that returns 0 on the assertion
# and non-zero on failure.

# ============================================================================
step 1 "MEASURED write accepted"
# ============================================================================
out=$(PSQL <<'SQL' 2>&1
BEGIN;
TRUNCATE kndb.fact, kndb_audit.evicted_fact, kndb.slot_kind, kndb.conflict_policy CASCADE;
INSERT INTO kndb.fact (entity_id, attribute, value, epistemic_kind, confidence, valid_time)
VALUES (1000, 'weight_kg', '82', 'MEASURED', 0.95,
        tstzrange('2026-01-01', 'infinity', '[)'));
DO $$
DECLARE n int;
BEGIN
  SELECT count(*) INTO n FROM kndb.fact WHERE entity_id=1000;
  IF n <> 1 THEN
    RAISE EXCEPTION 'expected 1 row, got %', n;
  END IF;
END $$;
ROLLBACK;
SQL
)
if [[ $? -eq 0 ]]; then pass "MEASURED row landed"; else fail "MEASURED write failed: $out"; fi

# ============================================================================
step 2 "R5: INFERRED into MEASURED-typed slot rejected"
# ============================================================================
out=$(PSQL <<'SQL' 2>&1
BEGIN;
TRUNCATE kndb.fact, kndb.slot_kind, kndb.conflict_policy CASCADE;
INSERT INTO kndb.slot_kind (attribute, required_kind) VALUES ('hba1c', 'MEASURED');
DO $$
BEGIN
  BEGIN
    INSERT INTO kndb.fact (entity_id, attribute, value, epistemic_kind, confidence, valid_time)
    VALUES (1001, 'hba1c', '7.2', 'INFERRED', 0.6,
            tstzrange('2026-01-01', 'infinity', '[)'));
    RAISE EXCEPTION 'FAILED: INFERRED into MEASURED slot was NOT rejected';
  EXCEPTION WHEN check_violation THEN
    -- expected
    NULL;
  END;
END $$;
ROLLBACK;
SQL
)
if [[ $? -eq 0 ]]; then pass "R5 rejected the slot-kind mismatch"; else fail "R5 did not fire: $out"; fi

# ============================================================================
step 3 "Precedence: high-conf INFERRED cannot displace lower-conf MEASURED"
# ============================================================================
out=$(PSQL <<'SQL' 2>&1
BEGIN;
TRUNCATE kndb.fact, kndb_audit.evicted_fact, kndb.slot_kind, kndb.conflict_policy CASCADE;
INSERT INTO kndb.fact (entity_id, attribute, value, epistemic_kind, confidence, valid_time)
VALUES (1002, 'ldl', '110', 'MEASURED', 0.90,
        tstzrange('2026-01-01', '2026-06-01', '[)'));
DO $$
BEGIN
  BEGIN
    INSERT INTO kndb.fact (entity_id, attribute, value, epistemic_kind, confidence, valid_time)
    VALUES (1002, 'ldl', '135', 'INFERRED', 0.97,
            tstzrange('2026-03-01', '2026-09-01', '[)'));
    RAISE EXCEPTION 'FAILED: high-conf INFERRED displaced MEASURED (lattice broken)';
  EXCEPTION WHEN check_violation THEN
    -- expected: INFERRED is outranked by MEASURED regardless of confidence
    NULL;
  END;
END $$;
DO $$
DECLARE alive int; existing_kind kndb.epistemic_kind;
BEGIN
  SELECT count(*) INTO alive
    FROM kndb.fact WHERE entity_id=1002 AND upper(sys_time)='infinity';
  SELECT epistemic_kind INTO existing_kind
    FROM kndb.fact WHERE entity_id=1002 AND upper(sys_time)='infinity' LIMIT 1;
  IF alive <> 1 OR existing_kind <> 'MEASURED' THEN
    RAISE EXCEPTION 'expected 1 live MEASURED row, got alive=% kind=%', alive, existing_kind;
  END IF;
END $$;
ROLLBACK;
SQL
)
if [[ $? -eq 0 ]]; then pass "prior MEASURED survived, INFERRED refused"; else fail "precedence lattice failed: $out"; fi

# ============================================================================
step 4 "Same-value absorb (idempotent)"
# ============================================================================
out=$(PSQL <<'SQL' 2>&1
BEGIN;
TRUNCATE kndb.fact, kndb_audit.evicted_fact, kndb.slot_kind, kndb.conflict_policy CASCADE;
INSERT INTO kndb.fact (entity_id, attribute, value, epistemic_kind, confidence, valid_time)
VALUES (1003, 'weight_kg', '80', 'MEASURED', 0.95, tstzrange('2026-01-01', '2026-03-01', '[)'));
INSERT INTO kndb.fact (entity_id, attribute, value, epistemic_kind, confidence, valid_time)
VALUES (1003, 'weight_kg', '80', 'MEASURED', 0.95, tstzrange('2026-02-15', '2026-05-01', '[)'));
DO $$
DECLARE n int; vt tstzrange;
BEGIN
  SELECT count(*) INTO n FROM kndb.fact WHERE entity_id=1003;
  SELECT valid_time INTO vt FROM kndb.fact WHERE entity_id=1003 LIMIT 1;
  IF n <> 1 THEN
    RAISE EXCEPTION 'expected 1 absorbed row, got %', n;
  END IF;
  IF NOT vt @> '2026-04-01'::timestamptz OR NOT vt @> '2026-01-15'::timestamptz THEN
    RAISE EXCEPTION 'absorbed valid_time did not widen: %', vt;
  END IF;
END $$;
ROLLBACK;
SQL
)
if [[ $? -eq 0 ]]; then pass "same-value overlap absorbed, valid_time widened"; else fail "same-value absorb failed: $out"; fi

# ============================================================================
step 5 "Viterbi join: 0.95 * 0.70 = 0.665"
# ============================================================================
out=$(PSQL <<'SQL' 2>&1
BEGIN;
TRUNCATE kndb.fact, kndb_audit.evicted_fact, kndb.slot_kind, kndb.conflict_policy CASCADE;
INSERT INTO kndb.fact (entity_id, attribute, value, epistemic_kind, confidence, valid_time) VALUES
  (1004, 'hba1c',       '7.2',  'MEASURED', 0.95, tstzrange('2026-01-01', 'infinity', '[)')),
  (1004, 'is_diabetic', 'true', 'INFERRED', 0.70, tstzrange('2026-01-01', 'infinity', '[)'));
SELECT kndb.refresh_weights();
DO $$
DECLARE jc numeric;
BEGIN
  SELECT round(provsql.sr_viterbi(provenance(), 'kndb.fact_weights')::numeric, 4)
    INTO jc
  FROM kndb.fact a
  JOIN kndb.fact b USING (entity_id)
  WHERE a.entity_id = 1004 AND a.attribute='hba1c'
    AND b.attribute='is_diabetic';
  IF abs(jc - 0.665) > 0.001 THEN
    RAISE EXCEPTION 'expected 0.665, got %', jc;
  END IF;
END $$;
ROLLBACK;
SQL
)
if [[ $? -eq 0 ]]; then pass "sr_viterbi returned 0.665 (within 0.001)"; else fail "Viterbi propagation failed: $out"; fi

# ============================================================================
step 6 "Bitemporal as_of returns point-in-time value"
# ============================================================================
out=$(PSQL <<'SQL' 2>&1
BEGIN;
TRUNCATE kndb.fact, kndb_audit.evicted_fact, kndb.slot_kind, kndb.conflict_policy CASCADE;
INSERT INTO kndb.fact (entity_id, attribute, value, epistemic_kind, confidence, valid_time) VALUES
  (1005, 'is_diabetic', 'false', 'INFERRED', 0.85, tstzrange('2020-01-01', '2022-01-01', '[)')),
  (1005, 'is_diabetic', 'true',  'INFERRED', 0.90, tstzrange('2022-01-01', 'infinity', '[)'));
DO $$
DECLARE v text;
BEGIN
  SELECT value INTO v FROM kndb.as_of_valid(1005, 'is_diabetic', '2021-06-15'::timestamptz);
  IF v <> 'false' THEN RAISE EXCEPTION 'expected false at 2021-06-15, got %', v; END IF;
  SELECT value INTO v FROM kndb.as_of_valid(1005, 'is_diabetic', '2023-06-15'::timestamptz);
  IF v <> 'true'  THEN RAISE EXCEPTION 'expected true at 2023-06-15, got %',  v; END IF;
END $$;
ROLLBACK;
SQL
)
if [[ $? -eq 0 ]]; then pass "as_of_valid returned correct historical belief"; else fail "bitemporal query failed: $out"; fi

# ============================================================================
step 7 "Progressive depth: expand(0/1/2) monotone"
# ============================================================================
out=$(PSQL <<'SQL' 2>&1
BEGIN;
TRUNCATE kndb.fact, kndb_audit.evicted_fact, kndb.slot_kind, kndb.conflict_policy CASCADE;
INSERT INTO kndb.fact (entity_id, attribute, value, epistemic_kind, confidence, valid_time) VALUES
  (1006, 'ldl',         '100',  'MEASURED', 0.95, tstzrange('2026-01-01', 'infinity', '[)')),
  (1006, 'bp_systolic', '130',  'MEASURED', 0.95, tstzrange('2026-01-01', 'infinity', '[)')),
  (1006, 'is_diabetic', 'true', 'INFERRED', 0.70, tstzrange('2026-01-01', 'infinity', '[)'));
INSERT INTO kndb.fact (entity_id, attribute, value, epistemic_kind, confidence, sources, valid_time)
SELECT 1006, 'avg_ldl_90d', '100', 'DERIVED', 0.80,
       ARRAY(SELECT fact_id FROM kndb.fact WHERE entity_id=1006 AND attribute='ldl'),
       tstzrange('2026-01-01', 'infinity', '[)');
DO $$
DECLARE r0 int; r1 int; r2 int; a0 numeric; a1 numeric; a2 numeric;
BEGIN
  SELECT count(*), avg(confidence) INTO r0, a0 FROM kndb.expand(1006, 0);
  SELECT count(*), avg(confidence) INTO r1, a1 FROM kndb.expand(1006, 1);
  SELECT count(*), avg(confidence) INTO r2, a2 FROM kndb.expand(1006, 2);
  IF NOT (r0 <= r1 AND r1 <= r2) THEN
    RAISE EXCEPTION 'recall not monotone: %-%-%', r0, r1, r2;
  END IF;
  IF NOT (a0 >= a1 AND a1 >= a2) THEN
    RAISE EXCEPTION 'avg conf not monotone: %-%-%', a0, a1, a2;
  END IF;
END $$;
ROLLBACK;
SQL
)
if [[ $? -eq 0 ]]; then pass "expand() recall up, avg-conf down monotonically"; else fail "progressive-depth failed: $out"; fi

# ============================================================================
step 8 "Use-permission views: INFERRED absent from compliance and training_safe"
# ============================================================================
out=$(PSQL <<'SQL' 2>&1
BEGIN;
TRUNCATE kndb.fact, kndb_audit.evicted_fact, kndb.slot_kind, kndb.conflict_policy CASCADE;
INSERT INTO kndb.fact (entity_id, attribute, value, epistemic_kind, confidence, valid_time) VALUES
  (1007, 'weight_kg',   '80',   'MEASURED', 0.95, tstzrange('2026-01-01', 'infinity', '[)')),
  (1007, 'is_diabetic', 'true', 'INFERRED', 0.70, tstzrange('2026-01-01', 'infinity', '[)'));
INSERT INTO kndb.fact (entity_id, attribute, value, epistemic_kind, confidence, sources, valid_time)
SELECT 1007, 'avg_weight_90d', '80', 'DERIVED', 0.85,
       ARRAY(SELECT fact_id FROM kndb.fact WHERE entity_id=1007 AND attribute='weight_kg'),
       tstzrange('2026-01-01', 'infinity', '[)');
DO $$
DECLARE c int; a int; t int;
BEGIN
  SELECT count(*) INTO c FROM kndb.fact_compliance    WHERE entity_id=1007;
  SELECT count(*) INTO a FROM kndb.fact_analytics     WHERE entity_id=1007;
  SELECT count(*) INTO t FROM kndb.fact_training_safe WHERE entity_id=1007;
  IF c <> 2 THEN RAISE EXCEPTION 'compliance expected 2 (MEASURED + DERIVED), got %', c; END IF;
  IF a <> 3 THEN RAISE EXCEPTION 'analytics expected 3 (all kinds), got %', a; END IF;
  IF t <> 1 THEN RAISE EXCEPTION 'training_safe expected 1 (MEASURED only), got %', t; END IF;
END $$;
ROLLBACK;
SQL
)
if [[ $? -eq 0 ]]; then pass "compliance excludes INFERRED, training_safe MEASURED-only"; else fail "use-permission views failed: $out"; fi

# ============================================================================
step 9 "Conflict + audit: kind_outranked reason recorded on eviction"
# ============================================================================
out=$(PSQL <<'SQL' 2>&1
BEGIN;
TRUNCATE kndb.fact, kndb_audit.evicted_fact, kndb.slot_kind, kndb.conflict_policy CASCADE;
INSERT INTO kndb.fact (entity_id, attribute, value, epistemic_kind, confidence, valid_time)
VALUES (1008, 'ldl', '135', 'INFERRED', 0.90, tstzrange('2026-01-01', '2026-06-01', '[)'));
INSERT INTO kndb.fact (entity_id, attribute, value, epistemic_kind, confidence, valid_time)
VALUES (1008, 'ldl', '110', 'MEASURED', 0.80, tstzrange('2026-03-01', '2026-09-01', '[)'));
DO $$
DECLARE alive int; audits int; reason_val text;
BEGIN
  SELECT count(*) INTO alive FROM kndb.fact WHERE entity_id=1008 AND upper(sys_time)='infinity';
  SELECT count(*) INTO audits FROM kndb_audit.evicted_fact
    WHERE (original_row->>'entity_id')::int = 1008;
  SELECT reason INTO reason_val FROM kndb_audit.evicted_fact
    WHERE (original_row->>'entity_id')::int = 1008 LIMIT 1;
  IF alive <> 1 THEN RAISE EXCEPTION 'expected 1 alive row, got %', alive; END IF;
  IF audits < 1 THEN RAISE EXCEPTION 'expected audit row, got 0'; END IF;
  IF reason_val <> 'kind_outranked' THEN RAISE EXCEPTION 'expected reason=kind_outranked, got %', reason_val; END IF;
END $$;
ROLLBACK;
SQL
)
if [[ $? -eq 0 ]]; then pass "eviction audited with reason=kind_outranked"; else fail "audit reason wrong: $out"; fi

# ============================================================================
end_ts=$(date +%s)
elapsed=$((end_ts - start_ts))

printf '\n\033[1m== SMOKE SUMMARY: %d pass, %d fail, %d s ==\033[0m\n' \
  "$pass_count" "$fail_count" "$elapsed"

if [[ $fail_count -gt 0 ]]; then
  exit 1
fi
