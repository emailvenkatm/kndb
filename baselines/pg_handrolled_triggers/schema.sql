-- Baseline B2 (STEELMAN): plain Postgres + hand-rolled trigger suite
-- that attempts to match KNDB's semantic guarantees without ProvSQL.
--
-- Reviewer objection this pre-empts: "your primitives are just
-- CHECK + trigger + RLS; anyone could write these triggers in a weekend."
-- Fine — here they are. LOC counted honestly by bench/loc.py. The paper
-- compares KNDB's engine primitives against THIS baseline, not against
-- the toothless B0/B1 baselines.
--
-- Guarantees this baseline reproduces:
--   Primitive 1 — epistemic-kind enforcement (R1..R5 mirroring KNDB).
--   Primitive 3 — write-time conflict resolution (invalidate + audit;
--                 reject policy also honored).
--   Primitive 4 — bitemporal storage via tstzrange + as_of query fn.
--   Primitive 5 — progressive-depth expand() function.
--
-- Does NOT reproduce:
--   Primitive 2 — Viterbi confidence propagation. This is the primitive
--   KNDB claims as most novel; hand-rolled triggers can compute joint
--   confidences on specific joins but do not give you propagation baked
--   into arbitrary query evaluation the way ProvSQL does. bench/
--   confidence_correctness.py measures the drift.

CREATE SCHEMA IF NOT EXISTS baseline_handrolled;
CREATE SCHEMA IF NOT EXISTS baseline_handrolled_audit;

DROP TABLE IF EXISTS baseline_handrolled.fact CASCADE;
DROP TABLE IF EXISTS baseline_handrolled.slot_kind CASCADE;
DROP TABLE IF EXISTS baseline_handrolled.conflict_policy CASCADE;
DROP TABLE IF EXISTS baseline_handrolled_audit.evicted_fact CASCADE;

CREATE TABLE baseline_handrolled.slot_kind (
  attribute      text PRIMARY KEY,
  required_kind  text NOT NULL CHECK (required_kind IN ('MEASURED','INFERRED','DERIVED'))
);

CREATE TABLE baseline_handrolled.conflict_policy (
  attribute  text PRIMARY KEY,
  policy     text NOT NULL CHECK (policy IN ('reject','invalidate'))
);

CREATE TABLE baseline_handrolled.fact (
  fact_id         uuid          PRIMARY KEY DEFAULT gen_random_uuid(),
  entity_id       int           NOT NULL,
  attribute       text          NOT NULL,
  value           text          NOT NULL,
  epistemic_kind  text          NOT NULL
                                CHECK (epistemic_kind IN ('MEASURED','INFERRED','DERIVED')),
  confidence      numeric(6,5)  NOT NULL CHECK (confidence >= 0.0 AND confidence <= 1.0),
  sources         uuid[]        NOT NULL DEFAULT '{}',
  valid_time      tstzrange     NOT NULL,
  sys_time        tstzrange     NOT NULL DEFAULT tstzrange(clock_timestamp(), 'infinity', '[)')
);

CREATE INDEX ix_bhr_ea       ON baseline_handrolled.fact (entity_id, attribute);
CREATE INDEX ix_bhr_kind     ON baseline_handrolled.fact (epistemic_kind);
CREATE INDEX ix_bhr_validgs  ON baseline_handrolled.fact USING gist (valid_time);

CREATE TABLE baseline_handrolled_audit.evicted_fact (
  audit_id       bigserial PRIMARY KEY,
  audit_time     timestamptz NOT NULL DEFAULT now(),
  reason         text NOT NULL,
  winner_fact_id uuid,
  original_row   jsonb NOT NULL
);

-- ---- Primitive 1 mirror -----------------------------------------------------

CREATE OR REPLACE FUNCTION baseline_handrolled.enforce_epistemic_kind()
RETURNS trigger LANGUAGE plpgsql AS $fn$
DECLARE
  required text;
  missing_src int;
BEGIN
  IF NEW.epistemic_kind = 'DERIVED' AND array_length(NEW.sources, 1) IS NULL THEN
    RAISE EXCEPTION 'B2 R1: DERIVED fact for attribute % has no sources', NEW.attribute
      USING ERRCODE = '23514';
  END IF;

  IF array_length(NEW.sources, 1) IS NOT NULL THEN
    SELECT count(*) INTO missing_src
    FROM unnest(NEW.sources) s(src_id)
    LEFT JOIN baseline_handrolled.fact f ON f.fact_id = s.src_id
    WHERE f.fact_id IS NULL;
    IF missing_src > 0 THEN
      RAISE EXCEPTION 'B2 R2: % source(s) do not resolve', missing_src
        USING ERRCODE = '23503';
    END IF;
  END IF;

  IF NEW.epistemic_kind = 'MEASURED' AND array_length(NEW.sources, 1) IS NOT NULL THEN
    RAISE EXCEPTION 'B2 R3: MEASURED fact cannot have sources'
      USING ERRCODE = '23514';
  END IF;

  IF NEW.epistemic_kind = 'INFERRED' AND NEW.confidence >= 1.0 THEN
    RAISE EXCEPTION 'B2 R4: INFERRED fact cannot claim certainty'
      USING ERRCODE = '23514';
  END IF;

  SELECT required_kind INTO required FROM baseline_handrolled.slot_kind WHERE attribute = NEW.attribute;
  IF FOUND AND required <> NEW.epistemic_kind THEN
    RAISE EXCEPTION 'B2 R5: attribute % is registered as %, got %',
      NEW.attribute, required, NEW.epistemic_kind
      USING ERRCODE = '23514';
  END IF;

  RETURN NEW;
END;
$fn$;

CREATE TRIGGER trg_bhr_epistemic
  BEFORE INSERT OR UPDATE ON baseline_handrolled.fact
  FOR EACH ROW EXECUTE FUNCTION baseline_handrolled.enforce_epistemic_kind();

-- ---- Primitive 3 mirror -----------------------------------------------------

CREATE OR REPLACE FUNCTION baseline_handrolled.resolve_conflict()
RETURNS trigger LANGUAGE plpgsql AS $fn$
DECLARE
  overlapping RECORD;
  policy      text;
BEGIN
  IF upper(NEW.sys_time) <> 'infinity' THEN
    RETURN NEW;
  END IF;

  FOR overlapping IN
    SELECT *
    FROM baseline_handrolled.fact f
    WHERE f.entity_id = NEW.entity_id
      AND f.attribute = NEW.attribute
      AND upper(f.sys_time) = 'infinity'
      AND f.valid_time && NEW.valid_time
      AND f.fact_id <> COALESCE(NEW.fact_id, gen_random_uuid())
  LOOP
    IF overlapping.value = NEW.value THEN
      UPDATE baseline_handrolled.fact
      SET valid_time = tstzrange(
                        LEAST (lower(valid_time), lower(NEW.valid_time)),
                        GREATEST(upper(valid_time), upper(NEW.valid_time)),
                        '[)')
      WHERE fact_id = overlapping.fact_id;
      RETURN NULL;
    END IF;

    SELECT cp.policy INTO policy
    FROM baseline_handrolled.conflict_policy cp
    WHERE cp.attribute = NEW.attribute;
    policy := COALESCE(policy, 'invalidate');

    IF policy = 'reject' THEN
      RAISE EXCEPTION 'B2 conflict: attribute % on entity % contradicts prior fact (policy=reject)',
        NEW.attribute, NEW.entity_id
        USING ERRCODE = '23514';
    ELSE
      INSERT INTO baseline_handrolled_audit.evicted_fact (reason, winner_fact_id, original_row)
      VALUES ('contradicted_by', NULL, to_jsonb(overlapping));
      UPDATE baseline_handrolled.fact
      SET sys_time = tstzrange(lower(sys_time), clock_timestamp(), '[)')
      WHERE fact_id = overlapping.fact_id
        AND lower(sys_time) < clock_timestamp();
    END IF;
  END LOOP;

  RETURN NEW;
END;
$fn$;

CREATE TRIGGER trg_bhr_conflict
  BEFORE INSERT ON baseline_handrolled.fact
  FOR EACH ROW EXECUTE FUNCTION baseline_handrolled.resolve_conflict();

-- ---- Primitive 4 mirror -----------------------------------------------------

CREATE OR REPLACE FUNCTION baseline_handrolled.as_of_valid(
  p_entity_id  int,
  p_attribute  text,
  p_valid_at   timestamptz
) RETURNS SETOF baseline_handrolled.fact
LANGUAGE sql STABLE AS $fn$
  SELECT *
  FROM baseline_handrolled.fact
  WHERE entity_id = p_entity_id
    AND attribute = p_attribute
    AND valid_time @> p_valid_at
    AND upper(sys_time) = 'infinity';
$fn$;

-- ---- Primitive 5 mirror -----------------------------------------------------

CREATE OR REPLACE FUNCTION baseline_handrolled.expand(
  p_entity_id  int,
  p_depth      int,
  p_min_conf   numeric DEFAULT 0.0
) RETURNS SETOF baseline_handrolled.fact
LANGUAGE sql STABLE AS $fn$
  SELECT *
  FROM baseline_handrolled.fact
  WHERE entity_id = p_entity_id
    AND upper(sys_time) = 'infinity'
    AND confidence >= p_min_conf
    AND (
      (p_depth >= 0 AND epistemic_kind = 'MEASURED')
      OR (p_depth >= 1 AND epistemic_kind = 'INFERRED')
      OR (p_depth >= 2 AND epistemic_kind = 'DERIVED')
    );
$fn$;

COMMENT ON SCHEMA baseline_handrolled IS
  'B2 steelman: hand-rolled triggers replicating KNDB primitives 1,3,4,5. Primitive 2 (Viterbi) is not reproduced.';
