-- epistemic--1.0.sql
--
-- SQL surface for the epistemic table AM:
--   * base type epistemic_kind (C I/O in src/epistemic_type.c)
--   * TAM handler epistemic_am_handler (src/epistemic_am.c)
--   * audit relation epistemic.evicted_fact
--   * slot registry epistemic.slot_kind (R5)
--   * source registry epistemic.source_registry (R2)
--
-- Custom WAL rmgr id 128 is registered in _PG_init (annotation
-- channel; see src/epistemic_wal.c).

\echo Use "CREATE EXTENSION epistemic" to load this file. \quit

-- Schema is created by the extension mechanism because epistemic.control
-- declares `schema = epistemic`. Do not CREATE SCHEMA here; PG 18 rejects
-- IF NOT EXISTS on the extension-owned schema at install time.

-- Base type for the epistemic kind. C I/O in src/epistemic_type.c.
CREATE FUNCTION epistemic.epistemic_kind_in(cstring)
    RETURNS epistemic.epistemic_kind
    AS 'MODULE_PATHNAME', 'epistemic_kind_in'
    LANGUAGE C IMMUTABLE STRICT;

CREATE FUNCTION epistemic.epistemic_kind_out(epistemic.epistemic_kind)
    RETURNS cstring
    AS 'MODULE_PATHNAME', 'epistemic_kind_out'
    LANGUAGE C IMMUTABLE STRICT;

CREATE TYPE epistemic.epistemic_kind (
    INPUT      = epistemic.epistemic_kind_in,
    OUTPUT     = epistemic.epistemic_kind_out,
    INTERNALLENGTH = 1,
    ALIGNMENT  = char,
    STORAGE    = plain,
    PASSEDBYVALUE
);

-- Table AM handler.
CREATE FUNCTION epistemic.epistemic_am_handler(internal)
    RETURNS table_am_handler
    AS 'MODULE_PATHNAME', 'epistemic_am_handler'
    LANGUAGE C;

CREATE ACCESS METHOD epistemic
    TYPE TABLE
    HANDLER epistemic.epistemic_am_handler;

COMMENT ON ACCESS METHOD epistemic IS
    'Native table AM enforcing epistemic kind, precedence, and audit at write time.';

-- Audit relation: rows evicted by the precedence lattice land here.
CREATE TABLE epistemic.evicted_fact (
    audit_id       bigserial PRIMARY KEY,
    audit_time     timestamptz NOT NULL DEFAULT clock_timestamp(),
    reason         text NOT NULL,
    winner_ctid    text,
    original_kind  epistemic.epistemic_kind NOT NULL,
    original_row   jsonb NOT NULL
);

CREATE INDEX ix_evicted_fact_reason ON epistemic.evicted_fact (reason);

-- Slot registry: attribute -> required epistemic_kind (R5 support).
CREATE TABLE epistemic.slot_kind (
    attribute      text PRIMARY KEY,
    required_kind  epistemic.epistemic_kind NOT NULL
);

-- Source registry: every source_id that may appear in a fact row's
-- `sources` array must be registered here (R2 semantics — advisor
-- decision, all-defaults). This is the "Option A" resolution model;
-- Option B (self-referential entity_ids) is documented in the paper
-- as a variant but not the demonstrated PoC choice.
CREATE TABLE epistemic.source_registry (
    source_id     text PRIMARY KEY,
    source_type   text NOT NULL,
    added_at      timestamptz NOT NULL DEFAULT clock_timestamp()
);

-- F21 test-only probe. Directly invokes table_tuple_insert_speculative
-- and table_tuple_complete_speculative on the target relation with a
-- caller-supplied candidate tuple. The SQL-level ON CONFLICT path is
-- not reachable on epistemic tables today (unique/exclusion index
-- creation fails at heap_getnext's rd_tableam identity check,
-- heapam.c:1352 REL_18_STABLE), so this probe is the only way to
-- exercise the F21 speculative-insertion callbacks. Used by
-- sql/am_speculative.sql to prove the R-checks fire on the speculative
-- path and to run the disable-and-test rebuild loop.
CREATE FUNCTION epistemic._probe_speculative_insert(
    relname         text,
    entity_id       int,
    attribute       text,
    value           text,
    sources         text[],
    valid_time      tstzrange,
    ep_kind         epistemic.epistemic_kind,
    ep_specificity  int2,
    ep_confidence   real,
    succeeded       bool DEFAULT true
) RETURNS text
    AS 'MODULE_PATHNAME', 'epistemic_probe_speculative_insert'
    LANGUAGE C;
