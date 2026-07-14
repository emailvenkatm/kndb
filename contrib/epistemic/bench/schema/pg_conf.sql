-- Baseline #3: evidence-weighted / confidence-merge.
--
-- Plain heap + BEFORE INSERT trigger that resolves conflicts by
-- ep_confidence alone. On tie by confidence, keep the incumbent
-- (first-committer). Ignores kind rank, specificity, and rule
-- checks other than the presence of ep_confidence itself.
--
-- This approximates truth-discovery / reliability-aware row-level
-- integration you see in Bayesian merge frameworks and confidence-
-- weighted CRDT variants. Correctness rate is high when confidences
-- differ and low when they tie or when a low-confidence MEASURED fact
-- competes against a high-confidence INFERRED fact.
--
-- Concretely for our workload:
--   * MEASURED / DERIVED writes always have ep_confidence = 1.0.
--   * INFERRED writes have ep_confidence uniform in [0, 1).
--   * Preseed is INFERRED with ep_confidence = 0.5.
-- So on ep_confidence alone: MEASURED and DERIVED (which happen to be
-- correct under the lattice) beat preseed via 1.0 > 0.5, but a
-- high-confidence INFERRED (say ep_confidence = 0.99) would beat a
-- MEASURED with ep_confidence exactly 1.0? No — 0.99 < 1.0, so
-- MEASURED wins. Where it fails is INFERRED-vs-INFERRED where the
-- lattice would use kind+specificity but this trigger uses only
-- confidence.

CREATE EXTENSION IF NOT EXISTS epistemic;

DROP TABLE IF EXISTS fact_conf;

CREATE TABLE fact_conf (
    entity_id      int NOT NULL,
    attribute      text NOT NULL,
    value          text,
    sources        text[],
    valid_time     tstzrange,
    sys_time       tstzrange DEFAULT tstzrange(now(), 'infinity'),
    ep_kind        epistemic.epistemic_kind NOT NULL,
    ep_specificity int2 NOT NULL DEFAULT 0,
    ep_confidence  real NOT NULL DEFAULT 1.0
);

-- Toggle: when 'off', the trigger DEGRADES to "always keep NEW"
-- (i.e. becomes LWW). Used by the disable-and-test transcript to
-- prove the confidence check is load-bearing for the correctness
-- rate this baseline achieves.
CREATE OR REPLACE FUNCTION fact_conf_setting()
RETURNS text LANGUAGE sql STABLE AS $$
    SELECT coalesce(current_setting('bench.fact_conf_mode', true), 'on')
$$;

CREATE OR REPLACE FUNCTION fact_conf_rules()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    inc_conf real;
    inc_ctid tid;
    mode text := fact_conf_setting();
BEGIN
    SELECT ep_confidence, ctid
      INTO inc_conf, inc_ctid
      FROM fact_conf
      WHERE entity_id = NEW.entity_id
        AND attribute = NEW.attribute
        AND upper(sys_time) = 'infinity'::timestamptz
      LIMIT 1
      FOR UPDATE;

    IF NOT FOUND THEN
        RETURN NEW;
    END IF;

    -- Disable-and-test knob: 'off' -> always overwrite (LWW).
    IF mode = 'off' THEN
        UPDATE fact_conf
           SET sys_time = tstzrange(lower(sys_time), clock_timestamp())
         WHERE ctid = inc_ctid;
        RETURN NEW;
    END IF;

    -- 'on': keep the row with strictly higher ep_confidence. On tie,
    -- keep the incumbent (first-committer-wins, matching KNDB's F8).
    IF NEW.ep_confidence <= inc_conf THEN
        RAISE EXCEPTION 'evidence-weighted: NEW_LOSES (confidence %<=%; %)',
            NEW.ep_confidence, inc_conf, 'first-committer'
            USING ERRCODE = 'check_violation';
    END IF;

    UPDATE fact_conf
       SET sys_time = tstzrange(lower(sys_time), clock_timestamp())
     WHERE ctid = inc_ctid;

    RETURN NEW;
END;
$$;

CREATE TRIGGER fact_conf_before_insert
    BEFORE INSERT ON fact_conf
    FOR EACH ROW EXECUTE FUNCTION fact_conf_rules();
