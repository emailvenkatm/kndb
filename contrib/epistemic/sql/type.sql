CREATE EXTENSION IF NOT EXISTS epistemic;
SELECT 'MEASURED'::epistemic.epistemic_kind;
SELECT 'inferred'::epistemic.epistemic_kind;      -- case-insensitive
SELECT 'Derived'::epistemic.epistemic_kind;
SELECT 'derived'::epistemic.epistemic_kind::text; -- round-trip
SELECT 'MeAsUrEd'::epistemic.epistemic_kind::text;
SELECT 'unknown'::epistemic.epistemic_kind;       -- SQLSTATE 22P02
