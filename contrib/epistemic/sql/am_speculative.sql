-- am_speculative.sql
--
-- F21 regression test for the tuple_insert_speculative /
-- tuple_complete_speculative override pair. Because the SQL-level
-- INSERT ... ON CONFLICT path is not reachable on epistemic tables
-- today (unique / exclusion constraint creation fails at heap_getnext's
-- rd_tableam identity check, heapam.c:1352 REL_18_STABLE), we exercise
-- the callbacks programmatically via epistemic._probe_speculative_insert,
-- which mirrors ExecInsert's two-phase call sequence
-- (nodeModifyTable.c:1189-1216 REL_18_STABLE) exactly.
--
-- Each cell asserts one of:
--   * the AM raises the expected R-violation, or
--   * the AM raises the expected precedence violation, or
--   * the tuple lands via the speculative-then-confirm path.

CREATE TABLE fact_spec (
    entity_id      int NOT NULL,
    attribute      text NOT NULL,
    value          text,
    sources        text[],
    valid_time     tstzrange,
    sys_time       tstzrange DEFAULT tstzrange(now(), 'infinity'),
    ep_kind        epistemic.epistemic_kind NOT NULL,
    ep_specificity int2 NOT NULL DEFAULT 0,
    ep_confidence  real NOT NULL DEFAULT 1.0
) USING epistemic;

INSERT INTO epistemic.source_registry (source_id, source_type)
    VALUES ('s1', 'llm-inference')
    ON CONFLICT DO NOTHING;

-- 1. Valid MEASURED via the speculative path succeeds.
SELECT epistemic._probe_speculative_insert(
    'fact_spec', 42, 'bp', 'measured-120/80', NULL,
    tstzrange('2026-01-01', 'infinity'),
    'MEASURED'::epistemic.epistemic_kind, 10::int2, 1.0::real);

SELECT count(*)::int AS after_measured FROM fact_spec
 WHERE entity_id = 42 AND attribute = 'bp';

-- 2. R3 violation on the speculative path: MEASURED with a non-empty
-- sources array must be rejected by epistemic_check_rules before the
-- speculative write reaches heap. If the F21 override is missing, this
-- lands silently (heap's speculative-insert body has no rule check).
SELECT epistemic._probe_speculative_insert(
    'fact_spec', 43, 'hr', 'forged', ARRAY['s1'],
    tstzrange('2026-01-01', 'infinity'),
    'MEASURED'::epistemic.epistemic_kind, 10::int2, 1.0::real);

SELECT count(*)::int AS after_r3_attempt FROM fact_spec
 WHERE entity_id = 43 AND attribute = 'hr';

-- 3. Valid INFERRED via the speculative path succeeds.
SELECT epistemic._probe_speculative_insert(
    'fact_spec', 44, 'rr', 'inferred-16', ARRAY['s1'],
    tstzrange('2026-01-01', 'infinity'),
    'INFERRED'::epistemic.epistemic_kind, 5::int2, 0.6::real);

SELECT count(*)::int AS after_inferred FROM fact_spec
 WHERE entity_id = 44 AND attribute = 'rr';

-- 4. R4 violation on the speculative path: INFERRED with conf=1.0 must
-- be rejected. Same failure mode as (2) if the override is missing.
SELECT epistemic._probe_speculative_insert(
    'fact_spec', 45, 'spo2', 'forged', ARRAY['s1'],
    tstzrange('2026-01-01', 'infinity'),
    'INFERRED'::epistemic.epistemic_kind, 10::int2, 1.0::real);

SELECT count(*)::int AS after_r4_attempt FROM fact_spec
 WHERE entity_id = 45 AND attribute = 'spo2';

-- 5. Precedence violation on the speculative path: an INFERRED/0.4
-- candidate against a MEASURED/1.0 incumbent must be rejected by the
-- precedence lattice (MEASURED beats INFERRED at equal specificity).
SELECT epistemic._probe_speculative_insert(
    'fact_spec', 42, 'bp', 'forged-inferred', ARRAY['s1'],
    tstzrange('2026-01-01', 'infinity'),
    'INFERRED'::epistemic.epistemic_kind, 10::int2, 0.4::real);

SELECT ep_kind::text AS incumbent_kind_after_precedence, ep_confidence
  FROM fact_spec
 WHERE entity_id = 42 AND attribute = 'bp' AND sys_time @> now();

-- 6. Precedence WIN + eviction on the speculative path: seed an
-- INFERRED/0.3 incumbent at a new slot, then a MEASURED/1.0 candidate
-- must WIN, evict the incumbent, and drop one audit row. This
-- exercises the deferred-eviction bookkeeping on the succeeded=true
-- branch of tuple_complete_speculative.
SELECT epistemic._probe_speculative_insert(
    'fact_spec', 46, 'temp', 'benign', ARRAY['s1'],
    tstzrange('2026-01-01', 'infinity'),
    'INFERRED'::epistemic.epistemic_kind, 10::int2, 0.3::real);
SELECT ep_kind::text AS before_evict FROM fact_spec
 WHERE entity_id = 46 AND attribute = 'temp' AND sys_time @> now();

TRUNCATE epistemic.evicted_fact RESTART IDENTITY;
SELECT epistemic._probe_speculative_insert(
    'fact_spec', 46, 'temp', 'measured-98.6', NULL,
    tstzrange('2026-01-01', 'infinity'),
    'MEASURED'::epistemic.epistemic_kind, 10::int2, 1.0::real);
SELECT ep_kind::text AS after_evict FROM fact_spec
 WHERE entity_id = 46 AND attribute = 'temp' AND sys_time @> now();
SELECT count(*)::int AS eviction_audit_rows FROM epistemic.evicted_fact;
SELECT reason FROM epistemic.evicted_fact ORDER BY audit_id;

-- 7. succeeded=false (abort branch) MUST NOT leave audit rows behind
-- even when precedence would have evicted. Seed a fresh incumbent
-- INFERRED/0.3 at (47,'pulse'), truncate audit, run a MEASURED/1.0
-- candidate with succeeded=false. The pending eviction must be
-- discarded; no audit row; incumbent survives.
SELECT epistemic._probe_speculative_insert(
    'fact_spec', 47, 'pulse', 'benign', ARRAY['s1'],
    tstzrange('2026-01-01', 'infinity'),
    'INFERRED'::epistemic.epistemic_kind, 10::int2, 0.3::real);
TRUNCATE epistemic.evicted_fact RESTART IDENTITY;
SELECT epistemic._probe_speculative_insert(
    'fact_spec', 47, 'pulse', 'measured-70', NULL,
    tstzrange('2026-01-01', 'infinity'),
    'MEASURED'::epistemic.epistemic_kind, 10::int2, 1.0::real,
    false);   -- succeeded=false: heap_abort_speculative kills the winner
SELECT ep_kind::text AS survived_kind FROM fact_spec
 WHERE entity_id = 47 AND attribute = 'pulse' AND sys_time @> now();
SELECT count(*)::int AS audit_rows_after_abort
  FROM epistemic.evicted_fact;

DROP TABLE fact_spec;
