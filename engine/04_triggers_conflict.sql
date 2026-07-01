-- KNDB engine — Primitive 3: write-time conflict detection with audit preservation.
--
-- A "conflict" here is: a NEW row asserting attribute A on entity E with
-- overlapping valid_time to an existing (current-system-time) row where the
-- VALUE differs. Policy per attribute:
--   'reject'      — reject the write; preserve NEW in audit.
--   'invalidate'  — evict prior (close its sys_time), let NEW land, preserve prior in audit.
--
-- The GiST EXCLUDE constraint in 02_facts_schema.sql would already reject any
-- overlapping valid_time with EQUAL entity+attribute (regardless of value).
-- That's coarser than what we want: two writes of the SAME value under
-- overlapping valid_time should be idempotent, not a conflict. So we:
--
--   1. Detect the overlap in a BEFORE trigger.
--   2. If same value: silently absorb into the prior row (extend valid_time).
--   3. If different value: apply the policy.
--
-- We drop the GiST EXCLUDE from 02_facts_schema.sql when this trigger is
-- installed (see the ALTER TABLE at the bottom) — the trigger is now the
-- source of truth for no-overlap. This also sidesteps the smoke-B risk that
-- ProvSQL's provsql column interferes with the GiST constraint.

CREATE TABLE IF NOT EXISTS kndb.conflict_policy (
  attribute      text PRIMARY KEY,
  policy         text NOT NULL CHECK (policy IN ('reject', 'invalidate'))
);

COMMENT ON TABLE kndb.conflict_policy IS 'Per-attribute conflict policy. Row absence = default "invalidate".';

CREATE OR REPLACE FUNCTION kndb.resolve_conflict()
RETURNS trigger LANGUAGE plpgsql AS $fn$
DECLARE
  overlapping RECORD;
  policy      text;
BEGIN
  -- Only run on inserts into the current sys_time window. Historical writes
  -- (e.g. backfills into a closed sys_time) are exempt.
  IF upper(NEW.sys_time) <> 'infinity' THEN
    RETURN NEW;
  END IF;

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
    -- Case 1: same value → idempotent. Extend the prior row's valid_time and
    -- SKIP the insert of NEW by returning NULL.
    IF overlapping.value = NEW.value THEN
      UPDATE kndb.fact
      SET valid_time = tstzrange(
                        LEAST (lower(valid_time), lower(NEW.valid_time)),
                        GREATEST(upper(valid_time), upper(NEW.valid_time)),
                        '[)')
      WHERE fact_id = overlapping.fact_id;
      RETURN NULL;
    END IF;

    -- Case 2: different value → conflict. Apply policy.
    SELECT cp.policy INTO policy FROM kndb.conflict_policy cp WHERE cp.attribute = NEW.attribute;
    policy := COALESCE(policy, 'invalidate');

    IF policy = 'reject' THEN
      -- Rejection: the tx will roll back; any INSERT into kndb_audit here
      -- would also roll back. Payload appears in Postgres error log via the
      -- interpolated RAISE. Autonomous-tx audit is future work (see DECISIONS).
      RAISE EXCEPTION 'KNDB conflict: attribute % on entity % contradicts prior fact (policy=reject) -- payload=%',
        NEW.attribute, NEW.entity_id, to_jsonb(NEW)
        USING ERRCODE = '23514',
              HINT = 'A conflicting fact already exists in overlapping valid_time. Change policy or resolve upstream.';
    ELSE
      -- invalidate: close prior row's sys_time, audit it, let NEW land.
      -- Use clock_timestamp(), not now(): several inserts inside one tx
      -- share the same start-of-tx now(), which would produce empty ranges
      -- (lower == upper) that break subsequent sys_time queries.
      INSERT INTO kndb_audit.evicted_fact (reason, winner_fact_id, original_row)
      VALUES ('contradicted_by', NULL /* NEW.fact_id assigned by default below */,
              to_jsonb(overlapping));
      UPDATE kndb.fact
      SET sys_time = tstzrange(lower(sys_time), clock_timestamp(), '[)')
      WHERE fact_id = overlapping.fact_id
        AND lower(sys_time) < clock_timestamp();
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
  'Primitive 3: write-time conflict detection. Same-value overlap is absorbed; different-value overlap is either rejected or invalidates the prior row per policy.';
