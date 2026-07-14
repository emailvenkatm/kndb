-- Baseline #1: last-write-wins.
--
-- Plain heap + BEFORE INSERT trigger that on every incoming write:
--   1. Finds the currently-live row for (entity_id, attribute) via a
--      seqscan (matches the other trigger baselines' shape).
--   2. If found, closes its sys_time upper bound to now() — bitemporal
--      eviction, identical audit shape to the KNDB AM path.
--   3. Lets NEW proceed. No content check, no rule check, no
--      arbitration.
--
-- We used to try the elegant partial-unique + ON CONFLICT DO UPDATE
-- shape here. It has a subtle problem: ON CONFLICT DO UPDATE mutates
-- the SAME physical row, so we lose the bitemporal history that the
-- other baselines produce. Worse, the reset-between-cells routine
-- (which identifies preseed rows by their exact (kind, spec, conf)
-- signature) then deletes the mutated preseed row because it no
-- longer matches the preseed shape. The trigger-based LWW shape
-- above matches every other baseline's write path exactly.
--
-- Semantics: newer writes always win. Never rejects on content
-- grounds. Correctness rate on adversarial mixes tends toward
-- "whichever kind happens to arrive last".

CREATE EXTENSION IF NOT EXISTS epistemic;

DROP TABLE IF EXISTS fact_lww;

CREATE TABLE fact_lww (
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

CREATE OR REPLACE FUNCTION fact_lww_rules()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    inc_ctid tid;
BEGIN
    SELECT ctid INTO inc_ctid
      FROM fact_lww
     WHERE entity_id = NEW.entity_id AND attribute = NEW.attribute
       AND upper(sys_time) = 'infinity'::timestamptz
     LIMIT 1
     FOR UPDATE;
    IF FOUND THEN
        UPDATE fact_lww
           SET sys_time = tstzrange(lower(sys_time), clock_timestamp())
         WHERE ctid = inc_ctid;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER fact_lww_before_insert
    BEFORE INSERT ON fact_lww
    FOR EACH ROW EXECUTE FUNCTION fact_lww_rules();
