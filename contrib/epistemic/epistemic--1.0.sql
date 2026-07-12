-- epistemic--1.0.sql
--
-- SQL surface for the epistemic table AM. The heavy lifting lives in C:
-- - table AM handler `epistemic_am_handler` returning a TableAmRoutine.
-- - custom WAL resource manager registered in _PG_init.
-- - base type `epistemic_kind` with C I/O.

\echo Use "CREATE EXTENSION epistemic" to load this file. \quit

CREATE SCHEMA IF NOT EXISTS epistemic;

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
