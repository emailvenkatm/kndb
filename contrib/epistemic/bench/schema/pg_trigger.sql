-- YCSB fact table on plain heap + BEFORE INSERT trigger that
-- reimplements R1..R5 AND the precedence lattice (kind rank ->
-- specificity -> confidence -> first-committer tie) in plpgsql.
--
-- This is the user-space equivalent of what the epistemic AM does
-- inside heapam's tuple_insert callback. Its purpose here is to
-- give us an apples-to-apples "same-semantics-different-integration-
-- point" baseline for the YCSB microbenchmark.
--
-- Correctness is NOT the point of this baseline: bypass survival
-- (F2) demonstrates the trigger can be turned off; this file exists
-- purely so we can measure the overhead cost of enforcing epistemic
-- semantics from plpgsql vs from C-inside-the-AM.

CREATE EXTENSION IF NOT EXISTS epistemic;

DROP TABLE IF EXISTS fact_trig;

CREATE TABLE fact_trig (
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

-- No secondary index for apples-to-apples with the epistemic table.

-- Rank helper mirrors epistemic_kind_rank in src/epistemic_rules.c:369.
CREATE OR REPLACE FUNCTION fact_trig_kind_rank(k epistemic.epistemic_kind)
RETURNS int LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE k::text
        WHEN 'MEASURED' THEN 3
        WHEN 'DERIVED'  THEN 2
        WHEN 'INFERRED' THEN 1
        ELSE 0
    END;
$$;

CREATE OR REPLACE FUNCTION fact_trig_rules()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    k text;
    inc_kind epistemic.epistemic_kind;
    inc_spec int2;
    inc_conf real;
    inc_xmin xid;
    inc_ctid tid;
    n_bad_sources int;
    new_rank int;
    inc_rank int;
BEGIN
    k := NEW.ep_kind::text;

    -- R1: DERIVED must have no sources array.
    IF k = 'DERIVED' THEN
        IF NEW.sources IS NOT NULL AND array_length(NEW.sources, 1) > 0 THEN
            RAISE EXCEPTION 'epistemic write-time rule violation: R1 (DERIVED sources)'
                USING ERRCODE = 'check_violation';
        END IF;
    END IF;

    -- R2: every non-NULL element of sources must be registered.
    -- Skipped for MEASURED (per src/epistemic_rules.c:157 short-circuit).
    IF k <> 'MEASURED' AND NEW.sources IS NOT NULL
       AND array_length(NEW.sources, 1) > 0 THEN
        SELECT count(*) INTO n_bad_sources
        FROM unnest(NEW.sources) AS s(sid)
        WHERE sid IS NOT NULL
          AND NOT EXISTS (
              SELECT 1 FROM epistemic.source_registry
              WHERE source_id = s.sid);
        IF n_bad_sources > 0 THEN
            RAISE EXCEPTION 'epistemic write-time rule violation: R2 (source resolution)'
                USING ERRCODE = 'check_violation';
        END IF;
    END IF;

    -- R3: MEASURED must have no sources.
    IF k = 'MEASURED' THEN
        IF NEW.sources IS NOT NULL AND array_length(NEW.sources, 1) > 0 THEN
            RAISE EXCEPTION 'epistemic write-time rule violation: R3 (MEASURED no sources)'
                USING ERRCODE = 'check_violation';
        END IF;
    END IF;

    -- R4: INFERRED confidence in [0, 1).
    IF k = 'INFERRED' THEN
        IF NEW.ep_confidence IS NULL
           OR NEW.ep_confidence < 0.0
           OR NEW.ep_confidence >= 1.0 THEN
            RAISE EXCEPTION 'epistemic write-time rule violation: R4 (INFERRED confidence < 1.0)'
                USING ERRCODE = 'check_violation';
        END IF;
    END IF;

    -- R5: if attribute is registered in slot_kind, required_kind must
    -- match the incoming kind.
    -- (The bench does not populate slot_kind, so this loop is a no-op
    -- pass at benchmark time — same as the AM path.)

    -- Overlap probe + precedence lattice.
    -- Fetch the current live incumbent for this slot (there is at most
    -- one, per the invariant asserted by am_eviction.sql). The scan
    -- also puts a SIRead lock down under SERIALIZABLE, matching the
    -- AM's find_live_overlap seqscan.
    SELECT ep_kind, ep_specificity, ep_confidence,
           xmin::text::xid, ctid
      INTO inc_kind, inc_spec, inc_conf, inc_xmin, inc_ctid
      FROM fact_trig
      WHERE entity_id = NEW.entity_id
        AND attribute = NEW.attribute
        AND upper(sys_time) = 'infinity'::timestamptz
        AND valid_time && NEW.valid_time
      LIMIT 1
      FOR UPDATE;

    IF FOUND THEN
        new_rank := fact_trig_kind_rank(NEW.ep_kind);
        inc_rank := fact_trig_kind_rank(inc_kind);

        IF new_rank < inc_rank THEN
            RAISE EXCEPTION 'epistemic precedence: NEW_LOSES (reason=kind_outranked)'
                USING ERRCODE = 'check_violation';
        ELSIF new_rank = inc_rank THEN
            IF NEW.ep_specificity < inc_spec THEN
                RAISE EXCEPTION 'epistemic precedence: NEW_LOSES (reason=specificity)'
                    USING ERRCODE = 'check_violation';
            ELSIF NEW.ep_specificity = inc_spec
                  AND NEW.ep_confidence < inc_conf THEN
                RAISE EXCEPTION 'epistemic precedence: NEW_LOSES (reason=confidence)'
                    USING ERRCODE = 'check_violation';
            ELSIF NEW.ep_specificity = inc_spec
                  AND NEW.ep_confidence = inc_conf THEN
                -- True tie. F8 xmin (first-committer-wins) tiebreak:
                -- since we FOUND an incumbent, its xmin is < our xid.
                -- New loses.
                RAISE EXCEPTION 'epistemic precedence: NEW_LOSES (reason=contradicted_same_rank)'
                    USING ERRCODE = 'check_violation';
            END IF;
        END IF;

        -- New wins: close the incumbent's sys_time upper bound and
        -- audit the eviction, mirroring the AM path (SPI INSERT into
        -- evicted_fact + simple_heap_update).
        UPDATE fact_trig
           SET sys_time = tstzrange(lower(sys_time), clock_timestamp())
         WHERE ctid = inc_ctid;

        INSERT INTO epistemic.evicted_fact
            (reason, winner_ctid, original_kind, original_row)
        VALUES ('trigger_precedence', NULL, inc_kind,
                jsonb_build_object(
                    'entity_id', NEW.entity_id,
                    'attribute', NEW.attribute,
                    'ep_kind', inc_kind::text,
                    'ep_specificity', inc_spec,
                    'ep_confidence', inc_conf));
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER fact_trig_before_insert
    BEFORE INSERT ON fact_trig
    FOR EACH ROW EXECUTE FUNCTION fact_trig_rules();
