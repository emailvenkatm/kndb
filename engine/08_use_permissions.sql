-- KNDB engine — Primitive 6: use permissions.
-- Compliance-scoped code paths select from kndb.fact_compliance.
-- Analytics paths select from kndb.fact_analytics.
-- Training-set builders select from kndb.fact_training_safe.
-- The distinction is not a WHERE-clause callers must remember; it is the
-- shape of the object they are querying.

CREATE OR REPLACE VIEW kndb.fact_compliance AS
  SELECT * FROM kndb.fact
   WHERE epistemic_kind <> 'INFERRED'
     AND upper(sys_time) = 'infinity';

CREATE OR REPLACE VIEW kndb.fact_analytics AS
  SELECT * FROM kndb.fact
   WHERE upper(sys_time) = 'infinity';

CREATE OR REPLACE VIEW kndb.fact_training_safe AS
  SELECT * FROM kndb.fact
   WHERE epistemic_kind = 'MEASURED'
     AND upper(sys_time) = 'infinity';

COMMENT ON VIEW kndb.fact_compliance    IS
  'Primitive 6: compliance-scoped facts (MEASURED + DERIVED). INFERRED excluded.';
COMMENT ON VIEW kndb.fact_analytics     IS
  'Primitive 6: analytics-scoped facts (all kinds, live rows only).';
COMMENT ON VIEW kndb.fact_training_safe IS
  'Primitive 6: model-training-safe facts (MEASURED only; excludes any model-derived value that could cause model-on-model training collapse).';
