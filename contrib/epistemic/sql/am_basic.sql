-- am_basic.sql: exercise the epistemic table AM insert path.
CREATE EXTENSION IF NOT EXISTS epistemic;

-- Register the source used by the INFERRED test below so R2 (source
-- resolution) does not preempt R4 (INFERRED confidence < 1.0).
INSERT INTO epistemic.source_registry (source_id, source_type)
VALUES ('x', 'test')
ON CONFLICT DO NOTHING;

CREATE TABLE fact (
    entity_id     int NOT NULL,
    attribute     text NOT NULL,
    value         text,
    sources       text[],
    valid_time    tstzrange,
    sys_time      tstzrange DEFAULT tstzrange(now(), 'infinity'),
    ep_kind       epistemic.epistemic_kind NOT NULL,
    ep_specificity int2 NOT NULL DEFAULT 0,
    ep_confidence real NOT NULL DEFAULT 1.0
) USING epistemic;

-- R3 pass: MEASURED with no sources.
INSERT INTO fact (entity_id, attribute, value, valid_time, ep_kind)
VALUES (1, 'bp', '120/80', tstzrange('2026-01-01', 'infinity'), 'MEASURED');

-- R3 fail: MEASURED with sources.
INSERT INTO fact (entity_id, attribute, value, sources, valid_time, ep_kind)
VALUES (2, 'bp', '130/85', ARRAY['x'], tstzrange('2026-01-01', 'infinity'), 'MEASURED');

-- R4 fail: INFERRED with confidence = 1.0. Provide sources to clear R2.
INSERT INTO fact (entity_id, attribute, value, sources, valid_time, ep_kind, ep_confidence)
VALUES (3, 'bp', '?', ARRAY['x'], tstzrange('2026-01-01', 'infinity'), 'INFERRED', 1.0);
