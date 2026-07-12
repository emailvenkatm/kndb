CREATE EXTENSION IF NOT EXISTS epistemic;

-- Register two sources.
INSERT INTO epistemic.source_registry (source_id, source_type) VALUES
    ('lab_a1c_2026_q1', 'lab_result'),
    ('device_bp_cuff_omron', 'device');

CREATE TABLE fact_r2 (
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

-- 1. DERIVED with all registered sources: PASS.
INSERT INTO fact_r2 (entity_id, attribute, value, sources, valid_time, ep_kind)
VALUES (10, 'a1c_control', 'true',
        ARRAY['lab_a1c_2026_q1', 'device_bp_cuff_omron'],
        tstzrange('2026-01-01', 'infinity'),
        'DERIVED');

-- 2. DERIVED with one unregistered source: R2 FAIL.
INSERT INTO fact_r2 (entity_id, attribute, value, sources, valid_time, ep_kind)
VALUES (11, 'a1c_control', 'true',
        ARRAY['lab_a1c_2026_q1', 'GHOST_SOURCE_999'],
        tstzrange('2026-01-01', 'infinity'),
        'DERIVED');

-- 3. INFERRED with empty sources: R2 FAIL.
INSERT INTO fact_r2 (entity_id, attribute, value, sources, valid_time, ep_kind, ep_confidence)
VALUES (12, 'a1c_estimate', '7.1',
        ARRAY[]::text[],
        tstzrange('2026-01-01', 'infinity'),
        'INFERRED', 0.7);

-- 4. MEASURED with no sources: R2 PASSES (delegates to R3).
INSERT INTO fact_r2 (entity_id, attribute, value, valid_time, ep_kind)
VALUES (13, 'bp', '120/80', tstzrange('2026-01-01', 'infinity'), 'MEASURED');

-- 5. Verify only rows 10 and 13 landed.
SELECT entity_id, ep_kind FROM fact_r2 ORDER BY entity_id;
