-- YCSB fact table on the epistemic access method.
-- Full rule + precedence + audit path runs inside heapam's tuple_insert
-- via the AM callback.

CREATE EXTENSION IF NOT EXISTS epistemic;

DROP TABLE IF EXISTS fact_ep;

CREATE TABLE fact_ep (
    entity_id      int NOT NULL,
    attribute      text NOT NULL,
    value          text,
    sources        text[],
    valid_time     tstzrange,
    sys_time       tstzrange DEFAULT tstzrange(now(), 'infinity'),
    ep_kind        epistemic.epistemic_kind NOT NULL,
    ep_specificity int2 NOT NULL DEFAULT 0,
    ep_confidence  real NOT NULL DEFAULT 1.0
) USING epistemic;

-- No secondary index: CREATE INDEX on a non-heap AM fails with
-- ERROR "only heap AM is supported" in PG 18. That error comes from
-- heap_getnext at src/backend/access/heap/heapam.c:1352 REL_18_STABLE,
-- which asserts `sscan->rs_rd->rd_tableam == GetHeapamTableAmRoutine()`
-- — the epistemic handler returns a distinct routine pointer (it
-- copies heapam's routine and overrides tuple_insert /
-- relation_toast_am), so the identity check fails. btree's ambuild
-- calls heap_getnext during the scan phase of index creation.
--
-- For apples-to-apples with the epistemic table, pg_heap and
-- pg_trigger tables ALSO drop the secondary index. All three
-- systems therefore serve reads via a seqscan of ~100k rows plus
-- the sys_time filter. This is a known limitation of this bench and
-- of the PoC AM; noted in bench/README.md.
