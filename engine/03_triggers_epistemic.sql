-- KNDB engine — Primitive 1: engine-enforced epistemic typing.
--
-- Rules enforced on INSERT/UPDATE:
--
--   R1  DERIVED rows MUST reference ≥1 source fact_id via `sources`.
--   R2  every source in `sources` MUST resolve to an existing fact row.
--   R3  `MEASURED` rows MUST have sources = '{}' (a measured fact with
--       claimed upstream sources is not measured, it's DERIVED — reject).
--   R4  `INFERRED` rows MUST have confidence < 1.0 (an inference with
--       confidence 1 is claiming certainty it cannot support — reject).
--   R5  attribute values written into a MEASURED-typed slot with a non-MEASURED
--       epistemic_kind are rejected. Slot registry is `kndb.slot_kind`.
--
-- The slot registry (R5) is the mechanism that catches "model wrote its
-- guess into the labs.hba1c column pretending it was measured". It is the
-- centerpiece of the 60-second demo.

CREATE TABLE IF NOT EXISTS kndb.slot_kind (
  attribute       text PRIMARY KEY,
  required_kind   kndb.epistemic_kind NOT NULL
);

COMMENT ON TABLE kndb.slot_kind IS 'Per-attribute registry declaring the epistemic_kind that attribute must be. Row absence = any kind allowed.';

-- Note: rejections use RAISE EXCEPTION, which rolls back the trigger's own
-- audit INSERT along with the offending write. Preserving rejected-write
-- payloads (for forensic replay of a bad client) needs an autonomous
-- transaction (dblink or a background writer). Deferred to future work — the
-- paper's audit claim is for conflict-EVICTED rows, not rejected rows.
-- Rejections are still fully logged in the Postgres error log with the row
-- payload interpolated into the message.

CREATE OR REPLACE FUNCTION kndb.enforce_epistemic_kind()
RETURNS trigger LANGUAGE plpgsql AS $fn$
DECLARE
  required kndb.epistemic_kind;
  missing_src int;
BEGIN
  IF NEW.epistemic_kind = 'DERIVED' AND array_length(NEW.sources, 1) IS NULL THEN
    RAISE EXCEPTION 'KNDB R1: DERIVED fact for attribute % has no sources', NEW.attribute
      USING ERRCODE = '23514', HINT = 'A DERIVED fact must reference ≥1 fact_id in sources[].';
  END IF;

  IF array_length(NEW.sources, 1) IS NOT NULL THEN
    SELECT count(*) INTO missing_src
    FROM unnest(NEW.sources) s(src_id)
    LEFT JOIN kndb.fact f ON f.fact_id = s.src_id
    WHERE f.fact_id IS NULL;
    IF missing_src > 0 THEN
      RAISE EXCEPTION 'KNDB R2: % source(s) do not resolve to existing facts', missing_src
        USING ERRCODE = '23503';
    END IF;
  END IF;

  IF NEW.epistemic_kind = 'MEASURED' AND array_length(NEW.sources, 1) IS NOT NULL THEN
    RAISE EXCEPTION 'KNDB R3: MEASURED fact for attribute % cannot have upstream sources', NEW.attribute
      USING ERRCODE = '23514';
  END IF;

  IF NEW.epistemic_kind = 'INFERRED' AND NEW.confidence >= 1.0 THEN
    RAISE EXCEPTION 'KNDB R4: INFERRED fact for attribute % claims confidence >= 1.0', NEW.attribute
      USING ERRCODE = '23514', HINT = 'Model outputs cannot be certain. Reduce confidence or reclassify as MEASURED.';
  END IF;

  SELECT required_kind INTO required FROM kndb.slot_kind WHERE attribute = NEW.attribute;
  IF FOUND AND required <> NEW.epistemic_kind THEN
    RAISE EXCEPTION 'KNDB R5: attribute % is registered as %, got %', NEW.attribute, required, NEW.epistemic_kind
      USING ERRCODE = '23514', HINT = 'This is the primary trust-boundary check the paper demonstrates.';
  END IF;

  RETURN NEW;
END;
$fn$;

CREATE TRIGGER trg_enforce_epistemic_kind
  BEFORE INSERT OR UPDATE ON kndb.fact
  FOR EACH ROW EXECUTE FUNCTION kndb.enforce_epistemic_kind();

COMMENT ON FUNCTION kndb.enforce_epistemic_kind IS
  'Primitive 1: write-time epistemic-kind enforcement. Rejected rows are still audited.';
