-- KNDB engine — the fact table.
--
-- Single-table design chosen over table-inheritance because:
--   (a) ProvSQL's add_provenance() must be re-applied per-table; single table
--       means one provenance surface.
--   (b) Progressive-depth queries scan one table with a WHERE on epistemic_kind
--       rather than UNION-ALL over three, keeping the plan simple.
--   (c) Reviewers can read one table definition and see the whole model.
--
-- The trade-off is that per-kind constraints are enforced via triggers rather
-- than schema. That's fine — the paper's claim is engine-enforced trust, and
-- a trigger is engine-enforcement. It is also what our steelman baseline (B2)
-- must reproduce.

CREATE TABLE kndb.fact (
  fact_id         uuid          PRIMARY KEY DEFAULT gen_random_uuid(),
  entity_id       int           NOT NULL,     -- e.g. patient_id
  attribute       text          NOT NULL,     -- e.g. 'hba1c', 'is_diabetic'
  value           text          NOT NULL,     -- text-serialized; typed views on top
  epistemic_kind  kndb.epistemic_kind NOT NULL,
  confidence      kndb.confidence NOT NULL,
  sources         uuid[]        NOT NULL DEFAULT '{}',   -- fact_ids of upstream facts
  valid_time      tstzrange     NOT NULL,     -- when the world-fact holds
  sys_time        tstzrange     NOT NULL DEFAULT tstzrange(clock_timestamp(), 'infinity', '[)'),
  writer          text          NOT NULL DEFAULT current_user,

  -- Bitemporal no-overlap for THIS entity+attribute WITHIN sys_time. The
  -- constraint runs as GiST EXCLUDE; if smoke B revealed an interaction with
  -- ProvSQL's hidden provsql column, engine/05_bitemporal.sql swaps this for
  -- a trigger-based enforcement.
  EXCLUDE USING gist (
    entity_id  WITH =,
    attribute  WITH =,
    valid_time WITH &&
  ) WHERE (upper(sys_time) = 'infinity')
);

CREATE INDEX ix_fact_entity_attr ON kndb.fact (entity_id, attribute);
CREATE INDEX ix_fact_kind        ON kndb.fact (epistemic_kind);
CREATE INDEX ix_fact_valid_time  ON kndb.fact USING gist (valid_time);

-- Audit table: never mutated by engine code, only INSERTed into by triggers.
CREATE TABLE kndb_audit.evicted_fact (
  audit_id       bigserial PRIMARY KEY,
  audit_time     timestamptz NOT NULL DEFAULT now(),
  reason         text NOT NULL,           -- 'contradicted_by' | 'epistemic_kind_violation' | ...
  winner_fact_id uuid,                    -- populated when a conflicting winner exists
  original_row   jsonb NOT NULL           -- full pre-eviction row payload
);

CREATE INDEX ix_evicted_reason ON kndb_audit.evicted_fact (reason);
CREATE INDEX ix_evicted_time   ON kndb_audit.evicted_fact (audit_time);

COMMENT ON TABLE kndb.fact               IS 'Every asserted fact. Engine enforces epistemic_kind semantics on write.';
COMMENT ON TABLE kndb_audit.evicted_fact IS 'Preserved copy of facts evicted by write-time conflict resolution or rejected by type check.';
