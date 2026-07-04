-- KNDB engine — epistemic-kind DOMAIN and per-row confidence type.
-- This file establishes the type-level distinctions the whole engine rests on.

-- The three epistemic kinds. Adding a fourth requires a paper edit and a
-- migration; this is intentionally short.
CREATE TYPE kndb.epistemic_kind AS ENUM (
  'MEASURED',   -- directly measured (lab result, sensor reading, user-declared)
  'INFERRED',   -- output of a model or rule
  'DERIVED'     -- deterministic aggregate of other facts (sources REQUIRED)
);

-- Confidence lives in [0, 1]. Domain enforces the range at write time.
CREATE DOMAIN kndb.confidence AS numeric(6,5)
  CHECK (VALUE >= 0.0 AND VALUE <= 1.0);

COMMENT ON TYPE   kndb.epistemic_kind IS 'Engine-enforced epistemic kind. See DESIGN.md §Primitive 1.';
COMMENT ON DOMAIN kndb.confidence     IS 'Numeric probability in [0,1], write-time-checked.';
