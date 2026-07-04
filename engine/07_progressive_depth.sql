-- KNDB engine — Primitive 5: progressive-depth expansion.
--
-- depth=0 → MEASURED only, confidence >= min_conf.
-- depth=1 → depth=0 plus INFERRED.
-- depth=2 → depth=1 plus DERIVED aggregates.
--
-- The paper's claim: as depth increases, recall goes up, average confidence
-- goes down — monotonically. Callers pick the tradeoff explicitly per query.

CREATE OR REPLACE FUNCTION kndb.expand(
  p_entity_id  int,
  p_depth      int,
  p_min_conf   numeric DEFAULT 0.0
) RETURNS SETOF kndb.fact
LANGUAGE sql STABLE AS $fn$
  SELECT *
  FROM kndb.fact
  WHERE entity_id = p_entity_id
    AND upper(sys_time) = 'infinity'
    AND confidence >= p_min_conf
    AND (
      (p_depth >= 0 AND epistemic_kind = 'MEASURED')
      OR (p_depth >= 1 AND epistemic_kind = 'INFERRED')
      OR (p_depth >= 2 AND epistemic_kind = 'DERIVED')
    );
$fn$;

COMMENT ON FUNCTION kndb.expand IS
  'Primitive 5: progressive-depth expansion. Higher depth = more recall, lower avg confidence.';
