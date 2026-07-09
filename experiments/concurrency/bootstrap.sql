-- Bootstrap the isolated concurrency-experiment database.
-- Runs against the postgres/system context. Assumes psql is invoked with a
-- superuser role that owns kndb_native (e.g. `kndb_native` on the Homebrew
-- native install).
--
-- Idempotent. Safe to re-run.

-- 1) DB creation. Cannot run inside a transaction, so we \gexec.
SELECT 'CREATE DATABASE kndb_concur OWNER kndb_native'
 WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = 'kndb_concur')
\gexec

-- 2) Search path for provsql on the new DB. Extension has to be added
--    once inside the DB itself (extension objects are database-scoped
--    even though the shared library is preloaded server-wide).
\c kndb_concur

ALTER DATABASE kndb_concur SET search_path = "$user", public, provsql;

CREATE EXTENSION IF NOT EXISTS uuid-ossp;
CREATE EXTENSION IF NOT EXISTS provsql CASCADE;
CREATE EXTENSION IF NOT EXISTS btree_gist;

-- 3) Engine files are applied by the concurrency Makefile's bootstrap
--    target, not here. This SQL file only ensures the DB exists and the
--    extensions are loaded.
