-- YCSB fact table on plain heap. No enforcement of R1..R5, no
-- precedence, no audit. This is the "PostgreSQL with no epistemic
-- semantics at all" baseline.

CREATE EXTENSION IF NOT EXISTS epistemic;   -- for the ep_kind type

DROP TABLE IF EXISTS fact_heap;

CREATE TABLE fact_heap (
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

-- No secondary index for apples-to-apples with the epistemic table
-- (which cannot support a btree in the PoC — see schema/epistemic.sql).
