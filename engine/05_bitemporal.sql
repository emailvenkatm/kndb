-- KNDB engine — Primitive 4: bitemporal query surface.
--
-- Storage (valid_time + sys_time as tstzrange) is already in 02_facts_schema.sql.
-- This file just adds the query surface:
--
--   kndb.as_of_valid(entity_id, attribute, at_valid_ts)
--     → what value did we claim was true AT world-time `at_valid_ts`, given
--       what the DB currently believes?
--
--   kndb.as_of_believed(entity_id, attribute, at_valid_ts, at_sys_ts)
--     → what value did we believe AT system-time `at_sys_ts` about world-time
--       `at_valid_ts`? This is the "did I know it on Tuesday" query.
--
-- Both are set-returning to handle overlapping siblings cleanly.

CREATE OR REPLACE FUNCTION kndb.as_of_valid(
  p_entity_id  int,
  p_attribute  text,
  p_valid_at   timestamptz
) RETURNS SETOF kndb.fact
LANGUAGE sql STABLE AS $fn$
  SELECT *
  FROM kndb.fact
  WHERE entity_id = p_entity_id
    AND attribute = p_attribute
    AND valid_time @> p_valid_at
    AND upper(sys_time) = 'infinity';
$fn$;

CREATE OR REPLACE FUNCTION kndb.as_of_believed(
  p_entity_id  int,
  p_attribute  text,
  p_valid_at   timestamptz,
  p_sys_at     timestamptz
) RETURNS SETOF kndb.fact
LANGUAGE sql STABLE AS $fn$
  SELECT *
  FROM kndb.fact
  WHERE entity_id = p_entity_id
    AND attribute = p_attribute
    AND valid_time @> p_valid_at
    AND sys_time  @> p_sys_at;
$fn$;

COMMENT ON FUNCTION kndb.as_of_valid    IS 'Primitive 4: what do we currently believe held at world-time p_valid_at.';
COMMENT ON FUNCTION kndb.as_of_believed IS 'Primitive 4: what did we believe on system-time p_sys_at about world-time p_valid_at.';
