-- Baseline B1: plain Postgres schema + Python app-layer guards.
--
-- Schema is identical in shape to B0 (naive) — the enforcement claim moves
-- into the Python layer in `guards.py`. This baseline exists to show that
-- app-layer guards are (a) additional LOC the app must ship and maintain,
-- (b) bypassable when writes go via any other path (a DBA, a migration, a
-- second service that skips the guard, a bulk COPY, an ORM shortcut), and
-- (c) hard to get exhaustively right.
--
-- Deliberately incomplete: no CHECK on epistemic_kind, no confidence range
-- check, no valid_time overlap constraint. All defenses come from Python.

CREATE SCHEMA IF NOT EXISTS baseline_pyguards;

DROP TABLE IF EXISTS baseline_pyguards.fact CASCADE;
DROP TABLE IF EXISTS baseline_pyguards.slot_kind CASCADE;

CREATE TABLE baseline_pyguards.slot_kind (
  attribute      text PRIMARY KEY,
  required_kind  text NOT NULL
);

CREATE TABLE baseline_pyguards.fact (
  fact_id         uuid          PRIMARY KEY DEFAULT gen_random_uuid(),
  entity_id       int           NOT NULL,
  attribute       text          NOT NULL,
  value           text          NOT NULL,
  epistemic_kind  text          NOT NULL,
  confidence      numeric       NOT NULL,
  sources         uuid[]        NOT NULL DEFAULT '{}',
  valid_time      tstzrange     NOT NULL,
  sys_time        tstzrange     NOT NULL DEFAULT tstzrange(clock_timestamp(), 'infinity', '[)')
);

CREATE INDEX ix_bpyg_ea ON baseline_pyguards.fact (entity_id, attribute);

COMMENT ON TABLE baseline_pyguards.fact IS
  'B1 py-guards baseline: enforcement lives in guards.py, not the schema.';
