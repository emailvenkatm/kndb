-- KNDB engine — Primitive 2: ProvSQL Viterbi confidence propagation.
--
-- We use ProvSQL v1.10.0's API:
--   add_provenance('tbl'::regclass)   — attach hidden `provsql uuid` column
--   provenance()                      — token for current row
--   set_prob(token, p::float8)        — assign a probability
--   sr_viterbi(token, weights)        — Viterbi semiring evaluation
--
-- Two accounting surfaces exist by design:
--   1. `confidence` numeric column — per-row scalar the app reads.
--   2. `provsql` UUID column — token used by ProvSQL semiring evaluation.
--
-- A trigger keeps `set_prob(provsql, confidence)` in sync so that any query
-- doing sr_viterbi or probability_evaluate against kndb.fact gets the same
-- number the app sees on the row.
--
-- Semantic note (see DECISIONS.md 2026-07-01 M0 smoke A):
-- ProvSQL's probability_evaluate on LEFT JOIN materializes possible-worlds
-- tuples (matched row + phantom "row missing" row). For KNDB user-facing
-- queries we surface the per-row `confidence` column and use ProvSQL only in
-- explicit propagation-demo queries. Both are honestly labeled in the demo.

SELECT add_provenance('kndb.fact'::regclass);

-- After INSERT/UPDATE-of-confidence, sync the ProvSQL probability from the row.
CREATE OR REPLACE FUNCTION kndb.sync_provsql_prob()
RETURNS trigger LANGUAGE plpgsql AS $fn$
BEGIN
  PERFORM provsql.set_prob(NEW.provsql, NEW.confidence::float8);
  RETURN NEW;
END;
$fn$;

CREATE TRIGGER trg_sync_provsql_prob
  AFTER INSERT OR UPDATE OF confidence ON kndb.fact
  FOR EACH ROW EXECUTE FUNCTION kndb.sync_provsql_prob();

-- Weight-table mapping keeps a numeric weight column derived from `confidence`
-- for sr_viterbi. Refreshed lazily via kndb.refresh_weights().
CREATE OR REPLACE FUNCTION kndb.refresh_weights() RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  DROP TABLE IF EXISTS kndb.fact_weights CASCADE;
  PERFORM provsql.create_provenance_mapping('kndb.fact_weights', 'kndb.fact', 'confidence::float');
END $$;

COMMENT ON FUNCTION kndb.sync_provsql_prob IS
  'Keep ProvSQL probability lockstep with per-row confidence. Runs AFTER INSERT/UPDATE.';
COMMENT ON FUNCTION kndb.refresh_weights IS
  'Rebuild the Viterbi weight-mapping table from kndb.fact.confidence.';
