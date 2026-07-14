-- Baseline #4: majority-vote / truth-discovery, streaming approximate.
--
-- Plain heap + BEFORE INSERT trigger that maintains a per-slot
-- count-min-style hashmap of observed values in an auxiliary table
-- and, on each write, picks the currently-most-frequent value for
-- the slot as the live row's `value`.
--
-- Design choice: streaming approximate rather than batched. The
-- batched variant (staging table + periodic vote flush) would be
-- fairer to majority-vote as a design, but it's off the closed-loop
-- YCSB path — writes would appear to succeed instantly and the
-- vote would resolve later. Since our correctness axis measures
-- the live row at the END of the measurement window, batched and
-- streaming converge in the limit. Streaming keeps the write path
-- comparable to the other trigger baselines.
--
-- Vote state:
--   fact_mv_votes(entity_id, attribute, value, votes)  -- (slot,value)->count
--
-- Trigger logic on each incoming NEW:
--   1. Increment vote count for (entity_id, attribute, NEW.value).
--   2. Find current winner value: argmax votes for this slot.
--      Ties broken by lexicographic value (deterministic).
--   3. If the winner value equals NEW.value, allow insert to proceed
--      (close incumbent sys_time, insert NEW).
--   4. Otherwise, REJECT with NEW_LOSES so the LWW-ish "row appears
--      even though it's a minority" doesn't happen. The winner (which
--      is already live) stays.
--
-- Correctness rate: reliably picks a hallucinated value if the majority
-- of writes are hallucinated (INFERRED low-confidence writes flooding).
--
-- Disable-and-test:
--   bench.fact_mv_min_votes = '1' (default) -> normal majority vote
--   bench.fact_mv_min_votes = '999999'      -> vote never fires,
--                                              always keeps incumbent
--                                              (approximates first-writer)
-- The paper's disable-and-test uses the more meaningful knob:
-- bench.fact_mv_mode = 'off' -> becomes LWW (always overwrite).

CREATE EXTENSION IF NOT EXISTS epistemic;

DROP TABLE IF EXISTS fact_mv;
DROP TABLE IF EXISTS fact_mv_votes;

CREATE TABLE fact_mv (
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

CREATE TABLE fact_mv_votes (
    entity_id int NOT NULL,
    attribute text NOT NULL,
    value     text NOT NULL,
    votes     int NOT NULL DEFAULT 0,
    PRIMARY KEY (entity_id, attribute, value)
);

CREATE OR REPLACE FUNCTION fact_mv_setting()
RETURNS text LANGUAGE sql STABLE AS $$
    SELECT coalesce(current_setting('bench.fact_mv_mode', true), 'on')
$$;

CREATE OR REPLACE FUNCTION fact_mv_rules()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    winner_value text;
    winner_votes int;
    inc_ctid tid;
    inc_value text;
    mode text := fact_mv_setting();
BEGIN
    -- Disable-and-test knob: pin vote count to 1 (never enforce),
    -- collapsing this baseline to LWW.
    IF mode = 'off' THEN
        SELECT ctid INTO inc_ctid
          FROM fact_mv
         WHERE entity_id = NEW.entity_id AND attribute = NEW.attribute
           AND upper(sys_time) = 'infinity'::timestamptz
         LIMIT 1
         FOR UPDATE;
        IF FOUND THEN
            UPDATE fact_mv
               SET sys_time = tstzrange(lower(sys_time), clock_timestamp())
             WHERE ctid = inc_ctid;
        END IF;
        RETURN NEW;
    END IF;

    -- Increment (slot, value) vote count.
    INSERT INTO fact_mv_votes (entity_id, attribute, value, votes)
    VALUES (NEW.entity_id, NEW.attribute, NEW.value, 1)
    ON CONFLICT (entity_id, attribute, value)
    DO UPDATE SET votes = fact_mv_votes.votes + 1;

    -- Pick current argmax value for this slot.
    SELECT value, votes
      INTO winner_value, winner_votes
      FROM fact_mv_votes
     WHERE entity_id = NEW.entity_id AND attribute = NEW.attribute
     ORDER BY votes DESC, value ASC
     LIMIT 1;

    -- Grab current live row.
    SELECT ctid, value
      INTO inc_ctid, inc_value
      FROM fact_mv
     WHERE entity_id = NEW.entity_id AND attribute = NEW.attribute
       AND upper(sys_time) = 'infinity'::timestamptz
     LIMIT 1
     FOR UPDATE;

    -- If NEW.value is the current majority-vote winner, install it
    -- (close incumbent + let insert proceed).
    IF NEW.value = winner_value THEN
        IF FOUND THEN
            IF inc_value = winner_value THEN
                -- Incumbent already IS the winner; reject NEW to avoid
                -- duplicate live row for the same value.
                RAISE EXCEPTION 'majority-vote: NEW_LOSES (already-winner)'
                    USING ERRCODE = 'check_violation';
            END IF;
            UPDATE fact_mv
               SET sys_time = tstzrange(lower(sys_time), clock_timestamp())
             WHERE ctid = inc_ctid;
        END IF;
        RETURN NEW;
    END IF;

    -- NEW is not the current majority winner; reject.
    RAISE EXCEPTION 'majority-vote: NEW_LOSES (minority; winner=%, votes=%)',
        left(coalesce(winner_value, ''), 16), winner_votes
        USING ERRCODE = 'check_violation';
END;
$$;

CREATE TRIGGER fact_mv_before_insert
    BEFORE INSERT ON fact_mv
    FOR EACH ROW EXECUTE FUNCTION fact_mv_rules();
