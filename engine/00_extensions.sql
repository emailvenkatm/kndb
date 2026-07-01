-- KNDB engine — extension load. Run once per fresh DB.
-- Must precede all other engine/*.sql files.

CREATE EXTENSION IF NOT EXISTS provsql CASCADE;
CREATE EXTENSION IF NOT EXISTS btree_gist;   -- required for GiST on (int, tstzrange)
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";  -- gen_random_uuid alternative if pgcrypto absent

CREATE SCHEMA IF NOT EXISTS kndb;
CREATE SCHEMA IF NOT EXISTS kndb_audit;

COMMENT ON SCHEMA kndb       IS 'KNDB user-facing objects: fact tables, epistemic-kind enforcement, propagation views.';
COMMENT ON SCHEMA kndb_audit IS 'Immutable audit trail for conflict-losers and write-time rejections. Never truncated by engine code.';
