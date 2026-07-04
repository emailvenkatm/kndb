-- Baseline B0: plain Postgres, no enforcement at all.
--
-- The point of this baseline: show what "just use Postgres" looks like when
-- the ternary MEASURED|INFERRED|DERIVED distinction is only a documented
-- convention, not an engine-checked property. Every adversarial write should
-- land silently. This is our floor.
--
-- Loaded into schema `baseline_naive`. Contains no CHECK constraints beyond
-- primary key, no triggers, no unique/exclusion constraints on
-- (entity, attribute, valid_time). The `epistemic_kind` column is a plain
-- text field with no domain check.

CREATE SCHEMA IF NOT EXISTS baseline_naive;

DROP TABLE IF EXISTS baseline_naive.fact CASCADE;

CREATE TABLE baseline_naive.fact (
  fact_id         uuid          PRIMARY KEY DEFAULT gen_random_uuid(),
  entity_id       int           NOT NULL,
  attribute       text          NOT NULL,
  value           text          NOT NULL,
  epistemic_kind  text          NOT NULL,     -- 'MEASURED' | 'INFERRED' | 'DERIVED', not enforced
  confidence      numeric       NOT NULL,     -- range not enforced
  sources         uuid[]        NOT NULL DEFAULT '{}',
  valid_time      tstzrange     NOT NULL,
  sys_time        tstzrange     NOT NULL DEFAULT tstzrange(clock_timestamp(), 'infinity', '[)')
);

CREATE INDEX ix_bnaive_ea ON baseline_naive.fact (entity_id, attribute);

COMMENT ON TABLE baseline_naive.fact IS
  'B0 naive baseline: plain PG, zero engine-level enforcement. Adversarial writes should all land.';
