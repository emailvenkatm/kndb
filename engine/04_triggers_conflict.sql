-- KNDB engine — Primitive 3: write-time conflict detection with audit preservation.
--
-- A "conflict" here is: a NEW row asserting attribute A on entity E with
-- overlapping valid_time to an existing (current-system-time) row where the
-- VALUE differs. v2 resolves the winner with an ordered precedence lattice:
--
--   1. Kind rank    MEASURED (3) > DERIVED (2) > INFERRED (1)
--   2. Specificity  higher wins  (per-row column; batch loaders write 0,
--                                 targeted writes default 100, adjudicated
--                                 corrections use higher)
--   3. Confidence   higher wins  (only consulted when kind and specificity tie)
--   4. All three tied and values differ: NEW lands, prior audited with reason
--      'contradicted_same_rank' (arrival order breaks the tie).
--
-- Same-value overlap is still absorbed idempotently (widens survivor's
-- valid_time) and is orthogonal to the lattice.
--
-- kndb.conflict_policy stays as an advisory override: policy='reject' for an
-- attribute short-circuits the lattice and refuses any conflict. Row absence
-- (or policy='invalidate') runs the lattice.
--
-- The GiST EXCLUDE constraint in 02_facts_schema.sql would already reject any
-- overlapping valid_time with EQUAL entity+attribute (regardless of value).
-- That's coarser than what we want: two writes of the SAME value under
-- overlapping valid_time should be idempotent, not a conflict. So we:
--
--   1. Detect the overlap in a BEFORE trigger.
--   2. If same value: silently absorb into the prior row (extend valid_time).
--   3. If different value: apply the reject policy if set, else the lattice.
--
-- We drop the GiST EXCLUDE from 02_facts_schema.sql when this trigger is
-- installed (see the ALTER TABLE at the bottom). The trigger is now the
-- source of truth for no-overlap. This also sidesteps the smoke-B risk that
-- ProvSQL's provsql column interferes with the GiST constraint.

CREATE TABLE IF NOT EXISTS kndb.conflict_policy (
  attribute      text PRIMARY KEY,
  policy         text NOT NULL CHECK (policy IN ('reject', 'invalidate'))
);

COMMENT ON TABLE kndb.conflict_policy IS 'Per-attribute conflict policy. Row absence = default lattice resolution.';

-- Kind-rank helper. MEASURED (3) > DERIVED (2) > INFERRED (1).
-- IMMUTABLE so the planner can inline it in comparisons.
CREATE OR REPLACE FUNCTION kndb.kind_rank(k kndb.epistemic_kind)
RETURNS smallint LANGUAGE sql IMMUTABLE AS $fn$
  SELECT CASE k
           WHEN 'MEASURED' THEN 3::smallint
           WHEN 'DERIVED'  THEN 2::smallint
           WHEN 'INFERRED' THEN 1::smallint
         END;
$fn$;

COMMENT ON FUNCTION kndb.kind_rank IS
  'Precedence rank for the conflict lattice. MEASURED (3) > DERIVED (2) > INFERRED (1).';

CREATE OR REPLACE FUNCTION kndb.resolve_conflict()
RETURNS trigger LANGUAGE plpgsql AS $fn$
DECLARE
  overlapping RECORD;
  policy      text;
  new_rank    smallint;
  old_rank    smallint;
  reason_code text;
BEGIN
  -- Only run on inserts into the current sys_time window. Historical writes
  -- (e.g. backfills into a closed sys_time) are exempt.
  IF upper(NEW.sys_time) <> 'infinity' THEN
    RETURN NEW;
  END IF;

  new_rank := kndb.kind_rank(NEW.epistemic_kind);

  -- Look for a current-fact overlap on (entity, attribute) with valid_time &&.
  FOR overlapping IN
    SELECT *
    FROM kndb.fact f
    WHERE f.entity_id = NEW.entity_id
      AND f.attribute = NEW.attribute
      AND upper(f.sys_time) = 'infinity'
      AND f.valid_time && NEW.valid_time
      AND f.fact_id <> COALESCE(NEW.fact_id, gen_random_uuid())
  LOOP
    -- Case 1: same value -> idempotent. Extend the prior row's valid_time and
    -- SKIP the insert of NEW by returning NULL. Orthogonal to the lattice.
    IF overlapping.value = NEW.value THEN
      UPDATE kndb.fact
      SET valid_time = tstzrange(
                        LEAST (lower(valid_time), lower(NEW.valid_time)),
                        GREATEST(upper(valid_time), upper(NEW.valid_time)),
                        '[)')
      WHERE fact_id = overlapping.fact_id;
      RETURN NULL;
    END IF;

    -- Case 2: different value -> conflict. Advisory reject-policy first.
    SELECT cp.policy INTO policy FROM kndb.conflict_policy cp WHERE cp.attribute = NEW.attribute;
    IF policy = 'reject' THEN
      -- Rejection short-circuit: preserved from v1 for the reject-policy test.
      -- The tx will roll back; any INSERT into kndb_audit here would also
      -- roll back. Payload appears in Postgres error log via the interpolated
      -- RAISE. Autonomous-tx audit is future work (see DECISIONS).
      RAISE EXCEPTION 'KNDB conflict: attribute % on entity % contradicts prior fact (policy=reject) -- payload=%',
        NEW.attribute, NEW.entity_id, to_jsonb(NEW)
        USING ERRCODE = '23514',
              HINT = 'A conflicting fact already exists in overlapping valid_time. Change policy or resolve upstream.';
    END IF;

    -- Case 3: run the precedence lattice. Stop at first tie-breaker.
    old_rank := kndb.kind_rank(overlapping.epistemic_kind);

    IF new_rank > old_rank THEN
      reason_code := 'kind_outranked';
    ELSIF new_rank < old_rank THEN
      reason_code := 'kind_outranked';
    ELSIF NEW.specificity > overlapping.specificity THEN
      reason_code := 'specificity';
    ELSIF NEW.specificity < overlapping.specificity THEN
      reason_code := 'specificity';
    ELSIF NEW.confidence > overlapping.confidence THEN
      reason_code := 'confidence';
    ELSIF NEW.confidence < overlapping.confidence THEN
      reason_code := 'confidence';
    ELSE
      reason_code := 'contradicted_same_rank';
    END IF;

    -- Determine winner. NEW wins outright when it outranks at the deciding
    -- tie-breaker; in a true tie NEW wins by arrival.
    IF (new_rank > old_rank)
       OR (new_rank = old_rank AND NEW.specificity > overlapping.specificity)
       OR (new_rank = old_rank AND NEW.specificity = overlapping.specificity
           AND NEW.confidence > overlapping.confidence)
       OR reason_code = 'contradicted_same_rank'
    THEN
      -- NEW wins: close prior row's sys_time, audit it, let NEW land.
      -- Use clock_timestamp(), not now(): several inserts inside one tx
      -- share the same start-of-tx now(), which would produce empty ranges
      -- (lower == upper) that break subsequent sys_time queries.
      INSERT INTO kndb_audit.evicted_fact (reason, winner_fact_id, original_row)
      VALUES (reason_code, NULL, to_jsonb(overlapping));
      UPDATE kndb.fact
      SET sys_time = tstzrange(lower(sys_time), clock_timestamp(), '[)')
      WHERE fact_id = overlapping.fact_id
        AND lower(sys_time) < clock_timestamp();
    ELSE
      -- NEW is outranked: refuse. Payload interpolated into the Postgres log.
      RAISE EXCEPTION 'KNDB precedence: NEW outranked by fact_id=%, reason=% -- payload=%',
        overlapping.fact_id, reason_code, to_jsonb(NEW)
        USING ERRCODE = '23514',
              HINT = 'Incoming fact lost the precedence lattice against an existing overlapping fact.';
    END IF;
  END LOOP;

  RETURN NEW;
END;
$fn$;

CREATE TRIGGER trg_resolve_conflict
  BEFORE INSERT ON kndb.fact
  FOR EACH ROW EXECUTE FUNCTION kndb.resolve_conflict();

-- The trigger is now the source of truth for no-overlap enforcement. Drop the
-- GiST EXCLUDE that duplicates (and coarsens) this check. Keeping the GiST
-- index for query planning; only the constraint goes.
ALTER TABLE kndb.fact DROP CONSTRAINT IF EXISTS fact_entity_id_attribute_valid_time_excl;

COMMENT ON FUNCTION kndb.resolve_conflict IS
  'Primitive 3: write-time conflict detection with precedence lattice (kind rank, specificity, confidence). Same-value overlap absorbed; reject-policy short-circuits.';
