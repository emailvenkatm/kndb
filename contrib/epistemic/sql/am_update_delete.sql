-- am_update_delete.sql: F20 UPDATE / DELETE rejection.
--
-- Exercises epistemic_tuple_update (rejects any change to the epistemic
-- prefix) and epistemic_tuple_delete (rejects DELETE outright) on the
-- native AM path. Companion of scripts/update_forgery.sh and
-- scripts/delete_forgery.sh; those two scripts run a full attack cycle
-- against a fresh cluster, while this regression test exercises the
-- callbacks under `make installcheck` on an existing cluster.
CREATE EXTENSION IF NOT EXISTS epistemic;

INSERT INTO epistemic.source_registry (source_id, source_type)
VALUES ('s_upd', 'test')
ON CONFLICT DO NOTHING;

CREATE TABLE fact_upd_del (
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

-- Seed with a legitimate INFERRED row.
INSERT INTO fact_upd_del (entity_id, attribute, value, sources, valid_time,
                          ep_kind, ep_specificity, ep_confidence)
VALUES (1, 'bp', 'benign', ARRAY['s_upd'],
        tstzrange('2026-01-01', 'infinity'),
        'INFERRED', 10, 0.4);

-- UPDATE that touches ONLY user columns (value): must succeed.
UPDATE fact_upd_del SET value = 'benign v2'
 WHERE entity_id = 1 AND attribute = 'bp';

-- UPDATE that changes ep_kind: must be rejected (F20).
UPDATE fact_upd_del SET ep_kind = 'MEASURED'::epistemic.epistemic_kind
 WHERE entity_id = 1 AND attribute = 'bp';

-- UPDATE that changes ep_confidence: must be rejected (F20).
UPDATE fact_upd_del SET ep_confidence = 1.0
 WHERE entity_id = 1 AND attribute = 'bp';

-- UPDATE that changes ep_specificity: must be rejected (F20).
UPDATE fact_upd_del SET ep_specificity = 20
 WHERE entity_id = 1 AND attribute = 'bp';

-- DELETE: must be rejected outright (F20).
DELETE FROM fact_upd_del WHERE entity_id = 1 AND attribute = 'bp';

-- Verify the seed row is intact (value updated to 'benign v2'; prefix
-- unchanged; row not removed).
SELECT entity_id, attribute, value, ep_kind, ep_specificity, ep_confidence
  FROM fact_upd_del
 WHERE entity_id = 1 AND attribute = 'bp';
